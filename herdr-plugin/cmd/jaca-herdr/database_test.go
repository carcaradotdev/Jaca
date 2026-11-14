package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"reflect"
	"runtime"
	"sort"
	"strings"
	"testing"
	"time"
)

// dbCall is one call the viewer made to jacad.
type dbCall struct {
	method  string
	params  map[string]any
	timeout time.Duration
}

// dbFake stands in for jacad: it records each call and answers with the JSON its method has
// here, or with the error.
type dbFake struct {
	made    []dbCall
	results map[string]string
	errs    map[string]string
	rows    func(table string, limit, offset int) string // database.rows, when set
	session bool                                         // jacad holds the session
	timers  []dbTimer                                    // what the viewer asked to run later
	chained int                                          // listings and pulls in flight,
	overlap bool                                         // and whether two ever were at once
}

type dbTimer struct {
	d time.Duration
	f func()
}

// fire runs the oldest timer.
func (f *dbFake) fire(t *testing.T) {
	t.Helper()
	if len(f.timers) == 0 {
		t.Fatal("no timer is waiting")
	}
	timer := f.timers[0]
	f.timers = f.timers[1:]
	timer.f()
}

func (f *dbFake) call(method string, params, out any, timeout time.Duration) error {
	m, _ := params.(map[string]any)
	f.made = append(f.made, dbCall{method, m, timeout})
	if msg, ok := f.errs[method]; ok {
		return errors.New(msg)
	}
	result, ok := f.results[method]
	switch {
	case method == "database.rows" && f.rows != nil:
		result, ok = f.rows(fmt.Sprint(m["table"]), m["limit"].(int), m["offset"].(int)), true
	case method == "database.open":
		result, ok = fmt.Sprintf(`{"id":%q,"existed":%v}`, m["id"], f.session), true
		f.session = true
	case method == "database.close":
		f.session = false
	}
	if !ok {
		return errors.New("no reply")
	}
	if out == nil {
		return nil
	}
	return json.Unmarshal([]byte(result), out)
}

// methods is the calls made since the last time it was asked, by name.
func (f *dbFake) methods() []string {
	var out []string
	for _, c := range f.made {
		out = append(out, c.method)
	}
	f.made = nil
	return out
}

func (f *dbFake) last(t *testing.T, method string) dbCall {
	t.Helper()
	for i := len(f.made) - 1; i >= 0; i-- {
		if f.made[i].method == method {
			return f.made[i]
		}
	}
	t.Fatalf("no %s call among %d", method, len(f.made))
	return dbCall{}
}

// dbPage is a page of the users table: 250 rows in all.
func dbPage(table string, limit, offset int) string {
	rs := dbResultSet{Columns: []string{"id", "name", "payload", "deleted_at"}, Rows: [][]*string{}}
	for i := offset; i < offset+limit && i < 250; i++ {
		id, name, payload := fmt.Sprint(i+1), fmt.Sprintf("%s %d", table, i+1), `{"b":1,"a":[true,null]}`
		rs.Rows = append(rs.Rows, []*string{&id, &name, &payload, nil})
	}
	raw, _ := json.Marshal(rs)
	return string(raw)
}

// testDBViewer is a viewer on a pane that has quit, whose calls go to a fake jacad. With queue
// nil each call's reply is handled at once; else the replies wait there to be run in any order.
func testDBViewer(t *testing.T, queue *[]func()) (*dbViewer, *dbFake) {
	t.Helper()
	quit := &pane{work: make(chan func()), done: make(chan struct{})}
	close(quit.done)
	v := makeDBViewer(quit, device{ID: "emulator-5554", Platform: "android", Model: "Pixel 8", State: "connected"}, nil)
	fake := &dbFake{errs: map[string]string{}, rows: dbPage, results: map[string]string{
		"database.close":     `true`,
		"devices.apps":       `[{"id":"com.android.settings","isUserApp":false},{"id":"com.example.shop","name":"Shop","isUserApp":true}]`,
		"database.databases": `[{"name":"app.db","path":"databases/app.db"},{"name":"cache.db","path":"databases/cache.db"}]`,
		"database.pull":      `[{"name":"users","rowCount":250},{"name":"odd\"name","rowCount":3}]`,
		"database.query":     `{"columns":["n"],"rows":[["1"]]}`,
	}}
	v.call = fake.call
	v.after = func(d time.Duration, f func()) { fake.timers = append(fake.timers, dbTimer{d, f}) }
	v.spawn = func(work func() func(), _ func()) {
		before := len(fake.made)
		done := work()
		// A listing or a pull is in flight from its call until its reply is handled.
		if len(fake.made) > before {
			if m := fake.made[before].method; m == "database.databases" || m == "database.pull" {
				fake.chained++
				fake.overlap = fake.overlap || fake.chained > 1
				reply := done
				done = func() {
					fake.chained--
					reply()
				}
			}
		}
		if queue == nil {
			done()
			return
		}
		*queue = append(*queue, done)
	}
	return v, fake
}

// openedDBViewer has picked the Shop app: its first database is pulled and the first page of
// its first table shows.
func openedDBViewer(t *testing.T) (*dbViewer, *dbFake) {
	t.Helper()
	v, fake := testDBViewer(t, nil)
	v.start()
	v.handleKey([]byte{'\r'})
	if v.appID != "com.example.shop" || v.result == nil {
		t.Fatalf("picking the first app left app %q, result %v, error %q", v.appID, v.result, v.err)
	}
	fake.methods()
	return v, fake
}

// dbText is the detail's content lines as last drawn, without their styles.
func dbText(v *dbViewer) []string {
	out := make([]string, len(v.detailDrawn))
	for i, line := range v.detailDrawn {
		out[i] = sgr.ReplaceAllString(line, "")
	}
	return out
}

// dbFind is where text starts in a frame: its row and column (1-based), 0 when it isn't there.
func dbFind(frame []string, text string) (y, x int) {
	for i, row := range frame {
		plain := sgr.ReplaceAllString(row, "")
		if at := strings.Index(plain, text); at >= 0 {
			return i + 1, cellWidth(plain[:at]) + 1
		}
	}
	return 0, 0
}

func dbClickOn(t *testing.T, v *dbViewer, frame []string, text string, button int) {
	t.Helper()
	y, x := dbFind(frame, text)
	if y == 0 {
		t.Fatalf("%q is not on screen:\n%s", text, frameText(frame))
	}
	v.mouse(mouseEvent{button: button, x: x, y: y, press: true})
	v.mouse(mouseEvent{button: button, x: x, y: y})
}

func TestDatabaseFlow(t *testing.T) {
	v, fake := testDBViewer(t, nil)
	v.start()
	// It opens on the apps, as the app's tab loads them when it opens.
	if got := fake.methods(); !reflect.DeepEqual(got, []string{"database.open", "devices.apps"}) {
		t.Fatalf("opening called %v", got)
	}
	if v.focus != dbApps || !strings.Contains(frameText(v.screenRows(30, 100)), "Search apps…") {
		t.Fatalf("the apps aren't showing:\n%s", frameText(v.screenRows(30, 100)))
	}
	// Left without a pick, the pane says what to do.
	v.handleKey([]byte{0x1b})
	text := frameText(v.screenRows(30, 100))
	if !strings.Contains(text, "Pick an app ▼") || !strings.Contains(text, "Pick an app to browse its local database.") {
		t.Fatalf("with no app picked:\n%s", text)
	}
	if strings.Contains(text, "SELECT") || strings.Contains(text, "snapshot") || strings.Contains(text, "DB") {
		t.Errorf("controls that need an app are showing:\n%s", text)
	}

	// Picking an app lists its databases, pulls the first and loads its first table.
	v.handleKey([]byte("a"))
	fake.methods()
	v.handleKey([]byte{'\r'}) // user apps come first
	if got := fake.methods(); !reflect.DeepEqual(got, []string{"database.databases", "database.pull", "database.rows"}) {
		t.Fatalf("picking an app called %v", got)
	}
	fake.made = nil
	v.refresh()
	if c := fake.last(t, "database.pull"); c.params["database"] != "databases/app.db" || c.params["package"] != "com.example.shop" || c.params["id"] != v.id || c.timeout != 2*time.Minute {
		t.Errorf("the pull was %+v", c)
	}
	if c := fake.last(t, "database.rows"); c.params["table"] != "users" || c.params["database"] != "databases/app.db" || c.params["limit"] != 100 || c.params["offset"] != 0 {
		t.Errorf("the first page was %+v", c)
	}
	if got := v.sql.String(); got != `SELECT * FROM "users"` {
		t.Errorf("the SQL box holds %q", got)
	}
	text = frameText(v.screenRows(30, 100))
	for _, want := range []string{"Shop ▼", "DB", "app.db ▼", "Table", "users ▼", "snapshot", "Refresh", `SELECT * FROM "users"`, "Run",
		"id", "deleted_at", "users 1", "NULL", "Prev", "page 1", "Next", "100 rows", "Help", "Pixel 8"} {
		if !strings.Contains(text, want) {
			t.Errorf("%q is missing:\n%s", want, text)
		}
	}

	// Next and Prev page through the table.
	offset := func() any { return fake.last(t, "database.rows").params["offset"] }
	v.handleKey([]byte("]"))
	if v.page != 1 || offset() != 100 {
		t.Errorf("after Next: page %d, offset %v", v.page, offset())
	}
	v.handleKey([]byte("n"))
	if v.page != 2 || offset() != 200 || len(v.result.Rows) != 50 {
		t.Errorf("the last page: page %d, offset %v, %d rows", v.page, offset(), len(v.result.Rows))
	}
	fake.made = nil
	v.handleKey([]byte("]")) // a short page has none after it
	if len(fake.made) != 0 || v.page != 2 {
		t.Errorf("Next on the last page called %v", fake.methods())
	}
	if text := frameText(v.screenRows(30, 100)); !strings.Contains(text, "page 3") || !strings.Contains(text, "50 rows") {
		t.Errorf("the last page reads:\n%s", text)
	}
	v.handleKey([]byte("["))
	v.handleKey([]byte("p"))
	if v.page != 0 || offset() != 0 {
		t.Errorf("after Prev twice: page %d, offset %v", v.page, offset())
	}
	fake.made = nil
	v.handleKey([]byte("["))
	if len(fake.made) != 0 {
		t.Errorf("Prev on the first page called %v", fake.methods())
	}

	// The Table menu lists each table with its row count, and picks by position.
	v.screenRows(30, 100)
	v.handleKey([]byte("t"))
	if v.focus != dbMenu || v.menu == nil || len(v.menu.items) != 2 || v.menu.items[0].label != "users (250)" || v.menu.items[1].label != `odd"name (3)` {
		t.Fatalf("the Table menu is %+v", v.menu)
	}
	if box := v.menu.box(30, 100); len(box) == 0 || v.menu.left != v.tableX || v.menu.top != v.barRows+1 {
		t.Errorf("the menu opened at %d,%d, the control is at column %d", v.menu.left, v.menu.top, v.tableX)
	}
	v.handleKey([]byte("j"))
	v.handleKey([]byte{'\r'})
	if c := fake.last(t, "database.rows"); c.params["table"] != `odd"name` || v.table != 1 || v.focus != dbGrid {
		t.Errorf("choosing the second table asked for %+v (table %d)", c.params, v.table)
	}
	if got := v.sql.String(); got != `SELECT * FROM "odd""name"` {
		t.Errorf("a quote in the name: %q", got)
	}

	// A custom query runs on the snapshot and lets go of the table.
	v.handleKey([]byte("s"))
	if v.focus != dbEditor {
		t.Fatal("s didn't focus the SQL box")
	}
	v.sql.set("SELECT 1 AS n")
	fake.made = nil
	v.handleKey([]byte{'\r'}) // the app's field submits on Return
	if c := fake.last(t, "database.query"); c.params["sql"] != "SELECT 1 AS n" || c.params["database"] != "databases/app.db" || c.timeout != 2*time.Minute {
		t.Errorf("the query was %+v", c)
	}
	if _, ok := v.tableName(); ok || !reflect.DeepEqual(v.result.Columns, []string{"n"}) {
		t.Errorf("after a query: table %d, columns %v", v.table, v.result.Columns)
	}
	v.handleKey([]byte{0x1b})
	text = frameText(v.screenRows(30, 100))
	if !strings.Contains(text, "— ▼") || strings.Contains(text, "users ▼") || strings.Contains(text, "page 1") || strings.Contains(text, "Prev") {
		t.Errorf("after a query the Table control and the pagination read:\n%s", text)
	}
	fake.made = nil
	v.handleKey([]byte("]"))
	if len(fake.made) != 0 {
		t.Errorf("Next with no table called %v", fake.methods())
	}
	// Ctrl+R and ⌘↩ run it from anywhere.
	for _, key := range []string{"\x12", "\x1b[13;9u"} {
		fake.made = nil
		v.handleKey([]byte(key))
		if got := fake.methods(); !reflect.DeepEqual(got, []string{"database.query"}) {
			t.Errorf("%q called %v", key, got)
		}
	}

	// Refresh pulls again and goes back to the first table's first page.
	v.handleKey([]byte("r"))
	if got := fake.methods(); !reflect.DeepEqual(got, []string{"database.pull", "database.rows"}) {
		t.Errorf("Refresh called %v", got)
	}
	if v.table != 0 || v.page != 0 || v.sql.String() != `SELECT * FROM "users"` {
		t.Errorf("after Refresh: table %d, page %d, SQL %q", v.table, v.page, v.sql.String())
	}

	// The other database, by its place in the DB menu.
	v.screenRows(30, 100)
	v.handleKey([]byte("d"))
	if v.menu == nil || len(v.menu.items) != 2 || v.menu.items[1].label != "cache.db" {
		t.Fatalf("the DB menu is %+v", v.menu)
	}
	v.menu.items[1].act()
	if c := fake.last(t, "database.pull"); c.params["database"] != "databases/cache.db" || v.selectedDB != 1 {
		t.Errorf("the second database pulled %+v", c.params)
	}

	// Leaving closes the session.
	if v.p.liveClose != "database.close" || v.p.liveID != v.id {
		t.Errorf("the pane's live session is %q %q", v.p.liveClose, v.p.liveID)
	}
	fake.made = nil
	v.leave(true)
	if c := fake.last(t, "database.close"); c.params["id"] != v.id || v.p.liveID != "" {
		t.Errorf("leaving called %+v, live id %q", c, v.p.liveID)
	}
}

func TestDatabaseOpenCarriesTheDevice(t *testing.T) {
	v, fake := testDBViewer(t, nil)
	v.start()
	c := fake.last(t, "database.open")
	if c.params["id"] != v.id || !isUUID(v.id) || c.params["device"] != v.device {
		t.Errorf("database.open was %+v", c.params)
	}
	if c := fake.last(t, "devices.apps"); c.params["deviceID"] != "emulator-5554" {
		t.Errorf("devices.apps was %+v", c.params)
	}
	// An app picked before the session is there waits for it.
	var queue []func()
	v, fake = testDBViewer(t, &queue)
	v.start()
	v.apps.loaded([]appEntry{{ID: "com.example.shop", IsUserApp: true}})
	v.handleKey([]byte{'\r'})
	if got := fake.methods(); !reflect.DeepEqual(got, []string{"database.open", "devices.apps"}) || !v.loading() {
		t.Fatalf("before the session opened: %v, loading %v", got, v.loading())
	}
	queue[0]()
	if got := fake.methods(); !reflect.DeepEqual(got, []string{"database.databases"}) {
		t.Errorf("once it opened: %v", got)
	}
	if got := frameText(v.screenRows(24, 80)); !strings.Contains(got, "shop ▼") {
		t.Errorf("an app with no name shows as:\n%s", got)
	}
}

// A listing or a pull never goes out while another is in flight: jacad would run both and keep
// whichever finished last. The last thing asked for goes out when the reply arrives, and that
// reply is dropped.
func TestDatabaseStepsGoOutOneAtATime(t *testing.T) {
	var queue []func()
	v, fake := testDBViewer(t, &queue)
	v.start()
	next := func() { // the oldest reply that waits
		t.Helper()
		if len(queue) == 0 {
			t.Fatal("no reply is waiting")
		}
		done := queue[0]
		queue = queue[1:]
		done()
	}
	run := func() {
		for len(queue) > 0 {
			next()
		}
	}
	run()
	v.focus = dbGrid
	fake.methods()

	// Two apps picked one after the other, before the first one's listing is back.
	v.selectApp("com.android.settings")
	v.selectApp("com.example.shop")
	if len(queue) != 1 || len(fake.made) != 1 || fake.made[0].params["package"] != "com.android.settings" {
		t.Fatalf("after two picks %d calls are out: %+v", len(queue), fake.made)
	}
	fake.methods()
	next()
	if len(v.databases) != 0 || !v.loading() {
		t.Fatalf("the first app's listing was taken: %d databases", len(v.databases))
	}
	if len(fake.made) != 1 || fake.made[0].method != "database.databases" || fake.made[0].params["package"] != "com.example.shop" {
		t.Fatalf("after the first listing came back: %+v", fake.made)
	}
	fake.methods()
	next()
	if len(v.databases) != 2 || v.selectedDB != 0 || len(queue) != 1 {
		t.Fatalf("the second app's listing: %d databases, %d calls out", len(v.databases), len(queue))
	}

	// The second database chosen before the first one's pull is back.
	v.selectDatabase(1)
	if got := fake.methods(); !reflect.DeepEqual(got, []string{"database.pull"}) || len(queue) != 1 {
		t.Fatalf("with a pull in flight, choosing a database called %v", got)
	}
	next()
	if len(v.tables) != 0 || v.pulled || !v.loading() {
		t.Fatalf("the first pull was taken: %d tables, pulled %v", len(v.tables), v.pulled)
	}
	if len(fake.made) != 1 || fake.made[0].method != "database.pull" || fake.made[0].params["database"] != "databases/cache.db" {
		t.Fatalf("after the first pull came back: %+v", fake.made)
	}
	run()
	if v.selectedDB != 1 || v.pulledPath != "databases/cache.db" || v.table != 0 || v.result == nil || v.loading() {
		t.Fatalf("the last choice: database %d, pulled %q, table %d", v.selectedDB, v.pulledPath, v.table)
	}
	if c := fake.last(t, "database.rows"); c.params["database"] != "databases/cache.db" {
		t.Errorf("the rows were read from %v", c.params["database"])
	}

	// Refresh pressed three times: one pull out, and one more after it for the rest.
	fake.methods()
	v.refresh()
	v.refresh()
	v.refresh()
	run()
	if got := fake.methods(); !reflect.DeepEqual(got, []string{"database.pull", "database.pull", "database.rows"}) {
		t.Errorf("three refreshes called %v", got)
	}
	// An app picked while a pull is in flight: the listing waits for it.
	v.refresh()
	v.selectApp("com.android.settings")
	if got := fake.methods(); !reflect.DeepEqual(got, []string{"database.pull"}) {
		t.Errorf("an app picked during a pull called %v", got)
	}
	run()
	if fake.overlap {
		t.Error("a listing and a pull were in flight together")
	}
	if v.appID != "com.android.settings" || v.selectedDB != 0 || v.result == nil {
		t.Errorf("after the app picked during a pull: app %q, database %d", v.appID, v.selectedDB)
	}
}

// A reply to a page or a query that another one replaced changes nothing, and neither of them
// costs the pane the reply to a pull.
func TestDatabaseStaleRepliesAreDropped(t *testing.T) {
	var queue []func()
	v, fake := testDBViewer(t, &queue)
	v.start()
	run := func() {
		for len(queue) > 0 {
			done := queue[0]
			queue = queue[1:]
			done()
		}
	}
	run()
	v.handleKey([]byte{'\r'})
	run()
	if v.table != 0 || v.result == nil || v.loading() {
		t.Fatalf("the flow stopped at table %d, result %v", v.table, v.result)
	}

	// Two pages asked for: the first one's rows come late.
	v.nextPage()
	v.nextPage()
	late, current := queue[0], queue[1]
	queue = nil
	current()
	if v.page != 2 || len(v.result.Rows) != 50 {
		t.Fatalf("page %d with %d rows", v.page, len(v.result.Rows))
	}
	late()
	if len(v.result.Rows) != 50 || v.loading() {
		t.Errorf("a late page replaced the rows: %d rows, loading %v", len(v.result.Rows), v.loading())
	}

	// A query replaced by a table: its result and its error come late.
	for _, failed := range []bool{false, true} {
		delete(fake.errs, "database.query")
		if failed {
			fake.errs["database.query"] = "SQLite: no such table: x"
		}
		v.sql.set("SELECT * FROM x")
		v.runQuery()
		v.selectTable(1)
		late, current = queue[0], queue[1]
		queue = nil
		current()
		late()
		if v.table != 1 || len(v.result.Columns) != 4 || v.err != "" {
			t.Errorf("a late query (failed %v) changed the pane: table %d, columns %v, error %q", failed, v.table, v.result.Columns, v.err)
		}
	}

	// Next during a Refresh: the page comes back first, and the pull is still taken.
	fake.results["database.pull"] = `[{"name":"fresh","rowCount":7}]`
	v.selectTable(0)
	run()
	v.refresh()
	v.nextPage()
	if len(queue) != 2 {
		t.Fatalf("%d replies waiting, want the pull and the page", len(queue))
	}
	pull, page := queue[0], queue[1]
	queue = nil
	page()
	if v.page != 1 || !v.loading() {
		t.Errorf("the page during a refresh: page %d, loading %v", v.page, v.loading())
	}
	pull()
	if len(v.tables) != 1 || v.tables[0].Name != "fresh" || v.table != 0 || v.page != 0 {
		t.Fatalf("the refresh was lost: tables %+v, page %d", v.tables, v.page)
	}
	run()
	if c := fake.last(t, "database.rows"); c.params["table"] != "fresh" || c.params["offset"] != 0 || v.loading() {
		t.Errorf("after the refresh the rows asked for were %+v", c.params)
	}
	// The other way round: the pull comes back first, and the page of the old snapshot is dropped.
	v.result.Rows = append(v.result.Rows, make([][]*string, 100-len(v.result.Rows))...)
	v.refresh()
	v.nextPage()
	pull, page = queue[0], queue[1]
	queue = nil
	pull()
	page()
	if v.page != 0 {
		t.Errorf("a page of the snapshot before was taken: page %d", v.page)
	}
	run()

	// A reply after the pane was left changes nothing.
	v.result.Rows = append(v.result.Rows, make([][]*string, 100)...)[:100]
	v.nextPage()
	v.leave(false)
	rows := v.result
	run()
	if v.result != rows {
		t.Error("a reply after leaving replaced the rows")
	}
}

// The session is touched every four minutes, and one jacad no longer holds is opened and
// pulled again by the next thing that needs it.
func TestDatabaseSessionIsKeptAndRecovered(t *testing.T) {
	v, fake := openedDBViewer(t)
	if len(fake.timers) != 1 || fake.timers[0].d != 4*time.Minute {
		t.Fatalf("the timers are %+v", fake.timers)
	}
	fake.fire(t)
	if got := fake.made; len(got) != 1 || got[0].method != "database.open" || got[0].params["id"] != v.id || got[0].params["device"] != v.device {
		t.Fatalf("the touch called %+v", got)
	}
	if len(fake.timers) != 1 || fake.timers[0].d != 4*time.Minute || !v.pulled {
		t.Fatalf("after a touch: %d timers, pulled %v", len(fake.timers), v.pulled)
	}

	// jacad closed the idle session: the touch brings back an empty one, and the next page
	// pulls the database again.
	fake.session = false
	fake.fire(t)
	if v.pulled {
		t.Fatal("a session that came back empty still counts as pulled")
	}
	fake.methods()
	v.nextPage()
	if got := fake.methods(); !reflect.DeepEqual(got, []string{"database.pull", "database.rows"}) || !v.pulled || v.page != 0 || v.err != "" {
		t.Errorf("the next page after that called %v (pulled %v, page %d, error %q)", got, v.pulled, v.page, v.err)
	}

	// A call answered with "No database session": shown, and the next action opens it again.
	fake.errs["database.rows"] = "No database session " + v.id + "."
	v.nextPage()
	if v.opened || v.pulled || v.p.liveID != "" || !strings.HasPrefix(v.err, "No database session ") {
		t.Fatalf("after the session was lost: opened %v, pulled %v, error %q", v.opened, v.pulled, v.err)
	}
	if frame := v.screenRows(24, 100); dbRedRow(frame, v.err) != v.editTop+v.editRows {
		t.Errorf("the error isn't under the SQL box:\n%s", frameText(frame))
	}
	delete(fake.errs, "database.rows")
	fake.session = false
	fake.methods()
	v.handleKey([]byte("\x12")) // Run
	if got := fake.methods(); !reflect.DeepEqual(got, []string{"database.open", "database.pull", "database.rows"}) {
		t.Errorf("the next action called %v", got)
	}
	if !v.opened || !v.pulled || v.err != "" || v.p.liveID != v.id || v.table != 0 {
		t.Errorf("after recovering: opened %v, pulled %v, error %q", v.opened, v.pulled, v.err)
	}
	// The same from a pull, and from an app with nothing selected yet.
	fake.errs["database.pull"] = "No database session " + v.id + "."
	v.refresh()
	delete(fake.errs, "database.pull")
	fake.methods()
	v.refresh()
	if got := fake.methods(); !reflect.DeepEqual(got, []string{"database.open", "database.pull", "database.rows"}) || v.err != "" {
		t.Errorf("Refresh after a lost session called %v (error %q)", got, v.err)
	}
	// jacad holds another database than the pane thinks.
	fake.errs["database.query"] = "No database pulled in session " + v.id + "."
	v.runQuery()
	delete(fake.errs, "database.query")
	fake.methods()
	if v.pulled || !v.opened {
		t.Errorf("after \"No database pulled\": pulled %v, opened %v", v.pulled, v.opened)
	}
	v.runQuery()
	if got := fake.methods(); !reflect.DeepEqual(got, []string{"database.pull", "database.rows"}) {
		t.Errorf("the next run called %v", got)
	}

	// A pane that was left touches nothing more.
	v.leave(true)
	fake.methods()
	timers := len(fake.timers)
	fake.fire(t)
	if len(fake.made) != 0 || len(fake.timers) != timers-1 {
		t.Errorf("a left pane touched: %v", fake.methods())
	}
}

// After another app or database is chosen the snapshot of the one before is not read, and the
// run keys do nothing while the SQL box isn't showing.
func TestDatabaseRunNeedsTheBoxAndItsSnapshot(t *testing.T) {
	v, fake := openedDBViewer(t)
	fake.errs["database.databases"] = "The app must be debuggable to read its database (run-as failed)."
	v.selectApp("com.android.settings")
	if v.pulled || v.showsSQL() {
		t.Fatalf("after an app that failed: pulled %v, SQL box %v", v.pulled, v.showsSQL())
	}
	v.sql.set("SELECT * FROM users")
	fake.methods()
	for _, key := range []string{"\x12", "\x1b[13;9u", "]", "[", "n", "p"} {
		v.handleKey([]byte(key))
	}
	v.focus = dbEditor
	v.handleKey([]byte{'\r'})
	v.runQuery()
	if len(fake.made) != 0 || v.focus != dbGrid {
		t.Errorf("with no SQL box the keys called %v (focus %d)", fake.methods(), v.focus)
	}
	if v.err != "The app must be debuggable to read its database (run-as failed)." {
		t.Errorf("the error became %q", v.err)
	}
	// A database whose pull fails leaves nothing to read either.
	v, fake = openedDBViewer(t)
	fake.errs["database.pull"] = "adb failed"
	v.selectDatabase(1)
	fake.methods()
	v.handleKey([]byte("\x12"))
	if v.pulled || len(fake.made) != 0 {
		t.Errorf("after a pull that failed: pulled %v, calls %v", v.pulled, fake.methods())
	}
}

func TestDatabaseIsReadOnly(t *testing.T) {
	for sql, want := range map[string]bool{
		"SELECT 1": true, "select * from t": true, "SeLeCt 1": true, "  \t\n\rSELECT 1": true, "WITH x AS (SELECT 1) SELECT * FROM x": true,
		"PRAGMA table_info(t)": true, "EXPLAIN QUERY PLAN SELECT 1": true, "selectx": true, "select": true, "with": true,
		"-- why\nSELECT 1": true, "-- a\n-- b\n  /* c */ select 1": true, "/* a */ /* b */\nSELECT 1": true, "/**/SELECT 1": true, "/*/ SELECT 1": true,
		"/* DELETE */ SELECT 1": true, "--\nSELECT 1": true, "-- SELECT 1": false, "/* SELECT 1": false, "/* a */": false,
		"": false, "   ": false, "DELETE FROM t": false, "UPDATE t SET a=1": false, "INSERT INTO t VALUES (1)": false, "DROP TABLE t": false,
		"; SELECT 1": false, "(SELECT 1)": false, "sel": false, "VACUUM": false, "ATTACH 'x' AS y": false, "- - x\nSELECT 1": false,
		"-- x\n DELETE FROM t -- SELECT": false, "/* SELECT */ DELETE FROM t": false, "\u00a0SELECT 1": false, "\vSELECT 1": false,
		// In Swift a carriage return and line feed are one character: neither whitespace to
		// drop nor the end of a line comment.
		"\r\nSELECT 1": false, "\n\rSELECT 1": true, "-- a\r\nSELECT 1": false, "-- a\r\n-- b\nSELECT 1": true, "\r \r\nSELECT 1": false,
		// A letter with a combining mark is another character.
		"select\u0301 1": false, "WITH\u0308": false,
	} {
		if got := dbIsReadOnly(sql); got != want {
			t.Errorf("%q: read-only %v, want %v", sql, got, want)
		}
	}
	for sql, want := range map[string]string{
		"  x": "x", "-- a\nx": "x", "-- a": "", "/* a */x": "x", "/* a": "", " /* a */ -- b\n /* c */ x -- d": "x -- d", "x": "x", "": "",
	} {
		if got := dbStripLeadingComments(sql); got != want {
			t.Errorf("%q stripped to %q, want %q", sql, got, want)
		}
	}
}

// dbRedRow is the first screen row drawn in red with this text, 0 when there is none.
func dbRedRow(frame []string, text string) int {
	for i, row := range frame {
		if strings.Contains(row, sgrRed+text) {
			return i + 1
		}
	}
	return 0
}

func TestDatabaseErrors(t *testing.T) {
	const notDebuggable = "The app must be debuggable to read its database (run-as failed)."
	const unsupported = "Database browsing isn't supported on this platform yet."

	// With nothing to show the error has the pane, in red, and there is no SQL box.
	for method, msg := range map[string]string{"database.databases": notDebuggable, "database.open": unsupported, "database.pull": "adb failed"} {
		v, fake := testDBViewer(t, nil)
		fake.errs[method] = msg
		v.start()
		v.handleKey([]byte{'\r'})
		frame := v.screenRows(24, 100)
		row := dbRedRow(frame, msg)
		if row < 4 || row > 20 || v.loading() {
			t.Errorf("%s failing: the error is on row %d (loading %v):\n%s", method, row, v.loading(), frameText(frame))
		}
		if text := frameText(frame); strings.Contains(text, "SELECT") || strings.Contains(text, "Run") {
			t.Errorf("%s failing: the SQL box shows:\n%s", method, text)
		}
		if method == "database.pull" {
			continue
		}
		// Picking the app again tries again.
		delete(fake.errs, method)
		v.handleKey([]byte("a"))
		v.handleKey([]byte{'\r'})
		if v.err != "" || v.result == nil {
			t.Errorf("%s: after it works again: error %q, result %v", method, v.err, v.result)
		}
	}

	// No database: the app's text, in red like its other errors.
	v, fake := testDBViewer(t, nil)
	fake.results["database.databases"] = `[]`
	v.start()
	v.handleKey([]byte{'\r'})
	if frame := v.screenRows(24, 100); dbRedRow(frame, "No SQLite database found for this app.") == 0 {
		t.Errorf("an app with no database:\n%s", frameText(frame))
	}
	if got := fake.methods(); got[len(got)-1] != "database.databases" {
		t.Errorf("with no database the viewer went on to %v", got)
	}

	// With rows on screen the error goes on the line under the SQL box and the rows stay.
	for _, msg := range []string{"SQLite: no such table: nope", "The result has more than 50000 rows. Add a LIMIT to the query.",
		"The result is larger than 64 MB. Select fewer rows or columns.", "SQLite: interrupted"} {
		v, fake = openedDBViewer(t)
		fake.errs["database.query"] = msg
		v.sql.set("SELECT * FROM nope")
		v.runQuery()
		frame := v.screenRows(24, 100)
		bar, _ := dbFind(frame, "SELECT * FROM nope")
		if row := dbRedRow(frame, msg); bar == 0 || row != bar+1 {
			t.Errorf("the query's error is on row %d, the SQL box on %d:\n%s", row, bar, frameText(frame))
		}
		if text := frameText(frame); !strings.Contains(text, "users 1") || strings.Contains(text, "page 1") || !strings.Contains(text, "— ▼") {
			t.Errorf("after a failed query the rows stay and the table is let go:\n%s", text)
		}
	}

	// A statement that is not read-only is refused here, as the app refuses it: its message,
	// nothing sent, and the result, the table and its pages as they were.
	v, fake = openedDBViewer(t)
	v.nextPage()
	result := v.result
	fake.methods()
	for _, sql := range []string{"DELETE FROM users", "", "-- SELECT\nDROP TABLE users"} {
		v.sql.set(sql)
		v.handleKey([]byte("\x12"))
		frame := v.screenRows(24, 100)
		if row := dbRedRow(frame, "Only read-only queries (SELECT/WITH/PRAGMA/EXPLAIN) are allowed."); row != v.editTop+v.editRows {
			t.Errorf("%q: the read-only message is on row %d:\n%s", sql, row, frameText(frame))
		}
		if text := frameText(frame); len(fake.made) != 0 || v.table != 0 || v.page != 1 || v.result != result || v.loading() || !strings.Contains(text, "page 2") {
			t.Errorf("%q: a refused statement changed the pane (calls %v, table %d, page %d):\n%s", sql, fake.methods(), v.table, v.page, text)
		}
	}
	// The next call that works takes the error away.
	v.sql.set("SELECT 1")
	v.runQuery()
	if frame := v.screenRows(24, 100); v.err != "" || strings.Contains(strings.Join(frame, ""), sgrRed) {
		t.Errorf("the error stayed: %q", v.err)
	}

	// A page that fails keeps the rows of the page before it.
	v, fake = openedDBViewer(t)
	fake.errs["database.rows"] = "SQLite: database disk image is malformed"
	v.nextPage()
	frame := v.screenRows(24, 100)
	if dbRedRow(frame, "SQLite: database disk image is malformed") != v.editTop+v.editRows || !strings.Contains(frameText(frame), "users 1") {
		t.Errorf("a failed page:\n%s", frameText(frame))
	}

	// A long error wraps onto a second row and is cut there.
	v.err = strings.Repeat("no such column ", 30)
	frame = v.screenRows(24, 60)
	if got := strings.Count(strings.Join(frame, ""), sgrRed); got != 2 {
		t.Errorf("a long error took %d rows", got)
	}
	checkWidths(t, "long error", frame, 24, 60)
}

func TestDatabaseEmptyStates(t *testing.T) {
	// A database with no tables: nothing selected, the SQL box usable.
	v, fake := testDBViewer(t, nil)
	fake.results["database.pull"] = `[]`
	v.start()
	v.handleKey([]byte{'\r'})
	text := frameText(v.screenRows(24, 100))
	if !strings.Contains(text, "No table selected.") || !strings.Contains(text, "SELECT … (read-only)") || !strings.Contains(text, "Run") {
		t.Errorf("a database with no tables:\n%s", text)
	}
	if strings.Contains(text, "Table") || strings.Contains(text, "Prev") || !strings.Contains(text, "snapshot") {
		t.Errorf("a database with no tables shows the wrong controls:\n%s", text)
	}
	v.handleKey([]byte("s"))
	for _, key := range "SELECT 1" {
		v.handleKey([]byte(string(key)))
	}
	v.handleKey([]byte{'\r'})
	if c := fake.last(t, "database.query"); c.params["sql"] != "SELECT 1" || v.result == nil {
		t.Errorf("a query typed with no table: %+v", c.params)
	}

	// A statement that returns no columns.
	fake.results["database.query"] = `{"columns":[],"rows":[]}`
	v.runQuery()
	if text := frameText(v.screenRows(24, 100)); !strings.Contains(text, "Query returned no columns.") || strings.Contains(text, "rows") {
		t.Errorf("no columns:\n%s", text)
	}

	// While the snapshot is pulled.
	var queue []func()
	v, _ = testDBViewer(t, &queue)
	v.start()
	queue[0]() // the session
	queue[1]() // the apps
	v.handleKey([]byte{'\r'})
	queue[2]() // the databases; the pull of the first one waits
	queue = queue[3:]
	if len(queue) != 1 || v.selectedDB != 0 || !v.loading() {
		t.Fatalf("%d replies waiting, database %d, loading %v", len(queue), v.selectedDB, v.loading())
	}
	frame := v.screenRows(24, 100)
	if text := frameText(frame); !strings.Contains(text, "Loading…") || !strings.Contains(text, cloudGlyphLoading) {
		t.Errorf("while pulling:\n%s", text)
	}
	// Run does nothing until a snapshot is there.
	before := len(queue)
	v.runQuery()
	if len(queue) != before {
		t.Error("a query ran with no snapshot")
	}

	// A table with no rows: its columns, no rows, no page after it.
	v, fake = testDBViewer(t, nil)
	fake.rows = func(string, int, int) string { return `{"columns":["id"],"rows":[]}` }
	v.start()
	v.handleKey([]byte{'\r'})
	if text := frameText(v.screenRows(24, 100)); !strings.Contains(text, "0 rows") || !strings.Contains(text, "page 1") || v.hasNextPage() {
		t.Errorf("an empty table:\n%s", text)
	}
	v.handleKey([]byte{'\r'})
	v.handleKey([]byte("C"))
	if v.detail {
		t.Error("Enter opened a detail with no row")
	}
}

func TestDatabasePagination(t *testing.T) {
	v, fake := openedDBViewer(t)
	frame := v.screenRows(24, 100)
	y, _ := dbFind(frame, "page 1")
	if y != 23 {
		t.Fatalf("the pagination bar is on row %d of 24:\n%s", y, frameText(frame))
	}
	// On the first page Prev is dim and does nothing; Next is a button.
	if !strings.Contains(frame[y-1], sgrDim+"Prev") || !strings.Contains(frame[y-1], sgrUnder+"Next") {
		t.Errorf("the first page's bar: %q", frame[y-1])
	}
	dbClickOn(t, v, frame, "Prev", 0)
	if len(fake.made) != 0 {
		t.Errorf("a click on a dim Prev called %v", fake.methods())
	}
	dbClickOn(t, v, frame, "Next", 0)
	if v.page != 1 {
		t.Fatalf("a click on Next left page %d", v.page)
	}
	frame = v.screenRows(24, 100)
	if !strings.Contains(frame[y-1], sgrUnder+"Prev") || !strings.Contains(frameText(frame), "page 2") {
		t.Errorf("the second page's bar: %q", frame[y-1])
	}
	dbClickOn(t, v, frame, "Next", 0)
	frame = v.screenRows(24, 100)
	if !strings.Contains(frame[y-1], sgrDim+"Next") || !strings.HasSuffix(strings.TrimRight(sgr.ReplaceAllString(frame[y-1], ""), " "), "50 rows") {
		t.Errorf("the last page's bar: %q", frame[y-1])
	}
	dbClickOn(t, v, frame, "Prev", 0)
	if v.page != 1 {
		t.Errorf("a click on Prev left page %d", v.page)
	}
	// A page of exactly 100 rows may have another after it, as in the app.
	v.result.Rows = v.result.Rows[:99]
	if v.hasNextPage() {
		t.Error("99 rows have a next page")
	}
}

func TestDatabaseRowDetail(t *testing.T) {
	v, _ := openedDBViewer(t)
	copied := captureClipboard(t)
	frame := v.screenRows(40, 140)
	if v.detail || v.detailX0 != 0 {
		t.Fatal("the detail is open before a row was chosen")
	}
	// A click on a row opens its detail; a click on it again closes it.
	dbClickOn(t, v, frame, "users 3", 0)
	if !v.detail || v.cursor != 2 {
		t.Fatalf("a click on the third row: detail %v, row %d", v.detail, v.cursor)
	}
	frame = v.screenRows(40, 140)
	dbClickOn(t, v, frame, "users 3", 0)
	if v.detail {
		t.Fatal("a second click left the detail open")
	}
	v.handleKey([]byte("j"))
	v.handleKey([]byte{'\r'})
	if !v.detail || v.cursor != 3 {
		t.Fatalf("Enter on the fourth row: detail %v, row %d", v.detail, v.cursor)
	}

	// Fields: each column's name over its whole value.
	frame = v.screenRows(40, 140)
	if text := frameText(frame); !strings.Contains(text, " Fields ") || !strings.Contains(text, " JSON ") || !strings.Contains(text, " Copy JSON ") || !strings.Contains(text, "esc close") {
		t.Fatalf("the detail's header:\n%s", text)
	}
	want := []string{"id", "4", "", "name", "users 4", "", "payload", `{"b":1,"a":[true,null]}`, "", "deleted_at", "NULL", ""}
	if !reflect.DeepEqual(dbText(v), want) {
		t.Errorf("the fields are %q", dbText(v))
	}

	// JSON: the row as the app writes it.
	const row = "{\n  \"id\": 4,\n  \"name\": \"users 4\",\n  \"payload\": {\n    \"a\" : [\n      true,\n      null\n    ],\n    \"b\" : 1\n  },\n  \"deleted_at\": null\n}"
	dbClickOn(t, v, frame, " JSON ", 0)
	if v.tab != dbTabJSON {
		t.Fatal("a click on JSON didn't switch the tab")
	}
	v.screenRows(40, 140)
	if got := strings.Join(dbText(v), "\n"); got != row {
		t.Errorf("the JSON tab reads:\n%s", got)
	}
	v.handleKey([]byte{'\t'})
	if v.tab != dbTabFields {
		t.Error("Tab didn't go back to Fields")
	}
	v.handleKey([]byte("2"))
	if v.tab != dbTabJSON {
		t.Error("2 didn't open JSON")
	}

	// Copy JSON, by its button and by C.
	frame = v.screenRows(40, 140)
	dbClickOn(t, v, frame, " Copy JSON ", 0)
	if got := <-copied; got != row {
		t.Errorf("Copy JSON copied %q", got)
	}
	v.handleKey([]byte("C"))
	if got := <-copied; got != row {
		t.Errorf("C copied %q", got)
	}

	// The detail follows the cursor, and Esc closes it before it leaves the pane.
	v.handleKey([]byte("1"))
	v.handleKey([]byte("k"))
	v.screenRows(40, 140)
	if dbText(v)[1] != "3" {
		t.Errorf("after moving up the detail shows row %q", dbText(v)[1])
	}
	left := false
	v.back = func() { left = true }
	v.handleKey([]byte{0x1b})
	if v.detail || left {
		t.Errorf("Esc: detail %v, left %v", v.detail, left)
	}
	v.handleKey([]byte{0x1b})
	if !left || !v.left {
		t.Error("a second Esc didn't go back")
	}
}

func TestDatabaseDetailSelection(t *testing.T) {
	v, _ := openedDBViewer(t)
	copied := captureClipboard(t)
	long := strings.Repeat("abcdefghij", 12)
	v.result.Rows[0][1] = &long
	v.toggleRow(0)
	v.screenRows(40, 140)
	at := func(line, col, button int, press bool) mouseEvent {
		return mouseEvent{button: button, x: v.detailX + col, y: v.detailFirst + line - v.detailTop, press: press}
	}
	// The long value wrapped: lines 4 on are its parts.
	if !v.detailMeta[5].cont || dbText(v)[4]+dbText(v)[5] != long[:len(dbText(v)[4])+len(dbText(v)[5])] {
		t.Fatalf("the long value didn't wrap: %q", dbText(v))
	}
	// A drag over two of its lines copies them as one piece.
	v.mouse(at(4, 2, 0, true))
	v.mouse(at(5, 3, mouseDrag, true))
	v.mouse(at(5, 3, 0, false))
	if got, want := <-copied, long[2:len(dbText(v)[4])+4]; got != want {
		t.Errorf("the drag copied %q, want %q", got, want)
	}
	if !strings.Contains(strings.Join(v.screenRows(40, 140), ""), sgrRev+"cdefghij") {
		t.Error("the selection isn't drawn")
	}
	// A double click copies the whole value.
	v.lastPress = time.Time{}
	v.mouse(at(5, 1, 0, true))
	v.mouse(at(5, 1, 0, false))
	v.mouse(at(5, 1, 0, true))
	if got := <-copied; got != long {
		t.Errorf("a double click copied %q", got)
	}
	v.mouse(at(5, 1, 0, false))
	// A right click offers Copy for the value under it.
	v.dsel = detailSel{}
	v.mouse(at(1, 0, 2, true))
	if v.focus != dbMenu || v.menu == nil || len(v.menu.items) != 1 || v.menu.items[0].label != "Copy" {
		t.Fatalf("a right click opened %+v", v.menu)
	}
	v.handleKey([]byte{'\r'})
	if got := <-copied; got != "1" || v.focus != dbGrid {
		t.Errorf("Copy copied %q", got)
	}
	// A click on a column's name selects nothing.
	v.mouse(at(0, 1, 0, true))
	v.mouse(at(0, 1, 0, false))
	select {
	case text := <-copied:
		t.Errorf("a click copied %q", text)
	default:
	}
	// A copy shows the notice.
	v.spawn = func(work func() func(), _ func()) { work()() }
	v.copy("x")
	<-copied
	if v.snack.text != "Copied" {
		t.Errorf("after a copy the notice reads %q", v.snack.text)
	}
}

// A double click selects exactly what it copies.
func TestDatabaseDetailDoubleClick(t *testing.T) {
	v, _ := openedDBViewer(t)
	copied := captureClipboard(t)
	poem := "line one\n" + strings.TrimSpace(strings.Repeat("two ", 40)) + "\n\nline four"
	v.result.Rows[0][1] = &poem
	v.toggleRow(0)
	v.screenRows(40, 140)
	double := func(line int) {
		t.Helper()
		v.lastPress = time.Time{}
		for i := 0; i < 2; i++ {
			v.mouse(mouseEvent{button: 0, x: v.detailX + 1, y: v.detailFirst + line - v.detailTop, press: true})
			v.mouse(mouseEvent{button: 0, x: v.detailX + 1, y: v.detailFirst + line - v.detailTop})
		}
	}
	// Fields: a value with line breaks is selected over all of its lines, wrapped ones too.
	text := dbText(v)
	if text[4] != "line one" || !v.detailMeta[6].cont || text[9] != "line four" || text[11] != "payload" {
		t.Fatalf("the value's lines are %q", text[:12])
	}
	for _, line := range []int{4, 6, 7, 9} {
		double(line)
		if got := <-copied; got != poem {
			t.Errorf("a double click on line %d copied %q", line, got)
		}
		if l0, _, l1, _ := v.dsel.ordered(); l0 != 4 || l1 != 9 || v.selectedDetailText() != poem {
			t.Errorf("a double click on line %d selected lines %d to %d: %q", line, l0, l1, v.selectedDetailText())
		}
	}
	double(1) // the id, a value of one line
	if got := <-copied; got != "1" || v.selectedDetailText() != "1" {
		t.Errorf("a double click on the id copied %q and selected %q", got, v.selectedDetailText())
	}

	// JSON: a line is a value. A long one that wrapped comes back whole.
	v.setTab(dbTabJSON)
	v.screenRows(40, 140)
	text = dbText(v)
	if text[1] != `  "id": 1,` || !v.detailMeta[3].cont {
		t.Fatalf("the JSON's lines are %q", text[:5])
	}
	double(1)
	if got := <-copied; got != `  "id": 1,` || v.selectedDetailText() != got {
		t.Errorf("a double click on a JSON line copied %q and selected %q", got, v.selectedDetailText())
	}
	double(3)
	want := `  "name": ` + dbQuote(poem) + `,`
	if got := <-copied; got != want || v.selectedDetailText() != want {
		t.Errorf("a double click on a wrapped JSON line copied %q and selected %q", got, v.selectedDetailText())
	}
	// Copy JSON and C still copy the document.
	v.handleKey([]byte("C"))
	if got := <-copied; got != dbRowJSON(v.result.Columns, v.result.Rows[0]) || !strings.HasPrefix(got, "{\n") {
		t.Errorf("C copied %q", got)
	}
}

// A row of huge cells costs a frame no more than a row of long ones: a value is laid out over
// a bounded number of lines, a frame looks only at the lines on screen, and the row's JSON is
// built for the JSON tab or a copy, not for Fields.
func TestDatabaseHugeCellsStayCheap(t *testing.T) {
	const cell = 5 << 20
	v, _ := openedDBViewer(t)
	copied := captureClipboard(t)
	rs := &dbResultSet{Columns: []string{"a", "b", "c", "d"}}
	for r := 0; r < 3; r++ {
		row := make([]*string, 4)
		for c := range row {
			row[c] = strPtr(strings.Repeat(fmt.Sprintf("%d%d 23456789abcde\n", r, c), cell/16))
		}
		rs.Rows = append(rs.Rows, row)
	}
	one := strings.Repeat("x", cell) // one line of 5 MB
	rs.Rows[2][0] = &one
	v.setResult(rs)
	allocated := func(f func()) uint64 {
		var before, after runtime.MemStats
		runtime.ReadMemStats(&before)
		f()
		runtime.ReadMemStats(&after)
		return after.TotalAlloc - before.TotalAlloc
	}
	const mb = 1 << 20
	v.toggleRow(0)
	if got := allocated(func() { v.screenRows(40, 140) }); got > 8*mb {
		t.Errorf("opening the detail allocated %d MB", got/mb)
	}
	if n := len(v.detailMeta); n < 4*cloudDetailLines || n > 4*(cloudDetailLines+2) {
		t.Errorf("four huge values are laid out over %d lines", n)
	}
	// A frame of what is already laid out, and a move to another row.
	if got := allocated(func() { v.screenRows(40, 140) }); got > 4*mb {
		t.Errorf("a frame allocated %d KB", got>>10)
	}
	for _, key := range []string{"j", "j", "k"} {
		if got := allocated(func() { v.handleKey([]byte(key)); v.screenRows(40, 140) }); got > 8*mb {
			t.Errorf("a move to another row allocated %d MB", got/mb)
		}
	}
	// The value of one 5 MB line is cut to what its lines can show.
	v.moveTo(2)
	v.screenRows(40, 140)
	if n := len(v.detailMeta); n > 4*(cloudDetailLines+2) || len(v.detailMeta[1].value) != cell {
		t.Errorf("a 5 MB line is laid out over %d lines", n)
	}
	// The JSON tab is bounded too, and scrolling it is as cheap as any frame.
	v.setTab(dbTabJSON)
	v.screenRows(40, 140)
	if n := len(v.detailMeta); n == 0 || n > cloudDetailLines*6 {
		t.Errorf("the JSON of a huge row is laid out over %d lines", n)
	}
	v.detailTop = 900
	if got := allocated(func() { v.screenRows(40, 140) }); got > 4*mb {
		t.Errorf("a frame of the JSON tab allocated %d KB", got>>10)
	}
	// What is copied is whole.
	v.handleKey([]byte("C"))
	if got := <-copied; len(got) < 3*cell || !strings.HasSuffix(got, "\n}") {
		t.Errorf("C copied %d bytes", len(got))
	}
	v.setTab(dbTabFields)
	v.screenRows(40, 140)
	v.lastPress = time.Time{}
	for i := 0; i < 2; i++ {
		v.mouse(mouseEvent{button: 0, x: v.detailX + 1, y: v.detailFirst + 1, press: true})
		v.mouse(mouseEvent{button: 0, x: v.detailX + 1, y: v.detailFirst + 1})
	}
	if got := <-copied; got != one {
		t.Errorf("a double click on the huge value copied %d bytes", len(got))
	}
}

func TestDatabaseGridScrolling(t *testing.T) {
	v, _ := openedDBViewer(t)
	wide := dbResultSet{}
	for c := 0; c < 12; c++ {
		wide.Columns = append(wide.Columns, fmt.Sprintf("col%02d", c))
	}
	for r := 0; r < 40; r++ {
		row := make([]*string, 12)
		for c := range row {
			text := fmt.Sprintf("r%dc%02d", r, c)
			row[c] = &text
		}
		wide.Rows = append(wide.Rows, row)
	}
	v.setResult(&wide)
	frame := v.screenRows(24, 100) // four whole columns
	if text := frameText(frame); !strings.Contains(text, "col00") || !strings.Contains(text, "col03") || strings.Contains(text, "col04") {
		t.Fatalf("a 100-cell pane shows:\n%s", frame[4])
	}
	// The header and the first cell of each column line up, 25 cells apart.
	if _, x := dbFind(frame, "col01"); x != 26 {
		t.Errorf("the second column starts at %d", x)
	}
	if _, x := dbFind(frame, "r0c01"); x != 26 {
		t.Errorf("the second column's first value starts at %d", x)
	}
	v.handleKey([]byte("\x1b[D"))
	if v.leftCol != 0 {
		t.Errorf("← at the first column moved to %d", v.leftCol)
	}
	for i := 0; i < 30; i++ {
		v.handleKey([]byte("\x1b[C"))
		v.screenRows(24, 100)
	}
	if v.leftCol != 8 {
		t.Errorf("→ stopped at column %d, want 8 (the last four whole)", v.leftCol)
	}
	if text := frameText(v.screenRows(24, 100)); !strings.Contains(text, "col11") || strings.Contains(text, "col07") {
		t.Errorf("scrolled to the end:\n%s", text)
	}
	// A wider pane holds more columns, so the scroll comes back in.
	v.screenRows(24, 200)
	if v.leftCol != 4 {
		t.Errorf("in a 200-cell pane the grid starts at column %d", v.leftCol)
	}
	// The wheel sideways, or with Shift.
	v.leftCol = 2
	v.mouse(mouseEvent{button: 68, x: 5, y: 8, press: true})
	v.mouse(mouseEvent{button: 66, x: 5, y: 8, press: true})
	v.mouse(mouseEvent{button: 66, x: 5, y: 8, press: true})
	if v.leftCol != 0 {
		t.Errorf("the wheel left stopped at %d", v.leftCol)
	}
	v.mouse(mouseEvent{button: 69, x: 5, y: 8, press: true})
	v.mouse(mouseEvent{button: 67, x: 5, y: 8, press: true})
	if v.leftCol != 2 {
		t.Errorf("the wheel right stopped at %d", v.leftCol)
	}

	// Rows: the keys move the cursor and the view follows; the wheel scrolls without it.
	v.screenRows(24, 100)
	room := v.gridRows
	v.handleKey([]byte("\x1b[6~"))
	if v.cursor != room {
		t.Errorf("PgDn moved to row %d, a page is %d", v.cursor, room)
	}
	v.handleKey([]byte("\x1b[F"))
	v.screenRows(24, 100)
	if v.cursor != 39 || v.top != 40-room {
		t.Errorf("End: row %d, first drawn %d", v.cursor, v.top)
	}
	v.handleKey([]byte("\x1b[B"))
	if v.cursor != 39 {
		t.Errorf("↓ on the last row moved to %d", v.cursor)
	}
	v.handleKey([]byte("\x1b[H"))
	v.handleKey([]byte("\x1b[A"))
	v.screenRows(24, 100)
	if v.cursor != 0 || v.top != 0 {
		t.Errorf("Home: row %d, first drawn %d", v.cursor, v.top)
	}
	v.mouse(mouseEvent{button: 65, x: 5, y: 8, press: true})
	v.screenRows(24, 100)
	if v.top != 3 || v.cursor != 0 {
		t.Errorf("the wheel: first drawn %d, row %d", v.top, v.cursor)
	}
	for i := 0; i < 40; i++ {
		v.mouse(mouseEvent{button: 65, x: 5, y: 8, press: true})
	}
	v.screenRows(24, 100)
	if v.top != 40-room {
		t.Errorf("the wheel scrolled to %d, past the last page at %d", v.top, 40-room)
	}
	// The selected row is a bar across the grid.
	v.moveTo(5)
	frame = v.screenRows(24, 100)
	y, _ := dbFind(frame, "r5c02")
	if y == 0 || !strings.HasPrefix(frame[y-1], sgrRev+sgrBold) || plainWidth(frame[y-1]) != 100 {
		t.Errorf("the selected row: %q", frame[y-1])
	}
}

func TestDatabaseToolbarAndEditorMouse(t *testing.T) {
	v, fake := openedDBViewer(t)
	frame := v.screenRows(30, 120)
	dbClickOn(t, v, frame, "Refresh", 0)
	if got := fake.methods(); !reflect.DeepEqual(got, []string{"database.pull", "database.rows"}) {
		t.Errorf("a click on Refresh called %v", got)
	}
	dbClickOn(t, v, frame, "app.db", 0)
	if v.focus != dbMenu || len(v.menu.items) != 2 {
		t.Fatalf("a click on the DB control: focus %d", v.focus)
	}
	// A click on a menu item picks it; a click elsewhere closes the menu.
	box := v.menu.box(30, 120)
	v.mouse(mouseEvent{button: 0, x: v.menu.left + 2, y: v.menu.top + 2, press: true})
	if len(box) == 0 || v.selectedDB != 1 || v.focus != dbGrid {
		t.Errorf("a click on the second database: database %d", v.selectedDB)
	}
	frame = v.screenRows(30, 120)
	dbClickOn(t, v, frame, "users ▼", 0)
	v.menu.box(30, 120)
	v.mouse(mouseEvent{button: 0, x: 100, y: 25, press: true})
	if v.focus != dbGrid || v.menu != nil || v.table != 0 {
		t.Errorf("a click outside the menu: focus %d, table %d", v.focus, v.table)
	}
	dbClickOn(t, v, frame, "Shop ▼", 0)
	if v.focus != dbApps {
		t.Fatal("a click on the app button didn't open the apps")
	}
	v.handleKey([]byte{0x1b})

	// A click in the SQL box gives it the keys, at that cell; Run runs it.
	frame = v.screenRows(30, 120)
	y, x := dbFind(frame, "FROM")
	v.mouse(mouseEvent{button: 0, x: x, y: y, press: true})
	if v.focus != dbEditor || v.sql.col != len("SELECT * ") {
		t.Fatalf("a click in the SQL box: focus %d, cursor %d", v.focus, v.sql.col)
	}
	v.handleKey([]byte("x"))
	if got := v.sql.String(); got != `SELECT * xFROM "users"` {
		t.Errorf("typing in the box: %q", got)
	}
	// Alt+Enter breaks the line, and the box grows to three rows.
	v.handleKey([]byte("\x1b\r"))
	v.handleKey([]byte("\x1b\r"))
	v.handleKey([]byte("\x1b\r"))
	v.screenRows(30, 120)
	if len(v.sql.lines) != 4 || v.editRows != 3 {
		t.Errorf("after three line breaks: %d lines in %d rows", len(v.sql.lines), v.editRows)
	}
	// q is text here, and Ctrl+C copies the selection instead of quitting.
	copied := captureClipboard(t)
	if v.handleKey([]byte("q")) || v.handleKey([]byte{0x03}) {
		t.Error("a key in the SQL box quit the pane")
	}
	v.handleKey([]byte{0x01})
	v.handleKey([]byte{0x03})
	if got := <-copied; !strings.HasPrefix(got, "SELECT * x\n\n\nq") {
		t.Errorf("Ctrl+C copied %q", got)
	}
	fake.made = nil
	frame = v.screenRows(30, 120)
	dbClickOn(t, v, frame, " Run ", 0)
	if c := fake.last(t, "database.query"); !strings.HasPrefix(fmt.Sprint(c.params["sql"]), "SELECT * x\n") {
		t.Errorf("Run sent %+v", c.params)
	}
	v.handleKey([]byte{0x1b})
	if v.focus != dbGrid || !v.handleKey([]byte("q")) {
		t.Error("Esc didn't give the keys back")
	}

	// Help, from the status bar and from the key.
	frame = v.screenRows(30, 120)
	dbClickOn(t, v, frame, "Help", 0)
	if v.focus != dbHelp {
		t.Fatal("a click on Help didn't open the keys")
	}
	box = keysBox(v.helpKeys(), 30, 120)
	if text := frameText(box); !strings.Contains(text, "Copy JSON") || !strings.Contains(text, "Row details") {
		t.Errorf("the keys popup:\n%s", text)
	}
	v.handleKey([]byte("?"))
	if v.focus != dbGrid {
		t.Error("? didn't close the keys")
	}
	// With no app picked a click on the pane, or Enter, opens the apps.
	v, _ = testDBViewer(t, nil)
	v.start()
	v.handleKey([]byte{0x1b})
	v.screenRows(30, 120)
	v.mouse(mouseEvent{button: 0, x: 40, y: 15, press: true})
	if v.focus != dbApps {
		t.Error("a click with no app picked didn't open the apps")
	}
	v.handleKey([]byte{0x1b})
	v.handleKey([]byte{'\r'})
	if v.focus != dbApps {
		t.Error("Enter with no app picked didn't open the apps")
	}
	if !v.handleKey([]byte{0x03}) {
		t.Error("Ctrl+C in the apps didn't quit")
	}
}

// dbNasty is a result whose text tries to break the frame: wide and combining characters,
// controls, escapes, direction marks, line breaks and a 10,000-character cell.
func dbNasty() *dbResultSet {
	values := []string{
		strings.Repeat("長い値", 3400),
		"\x1b[31mred\x1b[0m \x1b]0;title\x07 \x1b[2J\x1b[H",
		"tab\there\r\nline two\u202egnp.exe\u2066\u0085\u009b31m",
		strings.Repeat("x", 10000),
		"e\u0301\u0301\u0301 👩‍👩‍👧 🇧🇷 ✓",
		"",
		`{"k":"` + strings.Repeat("v", 3000) + `"}`,
	}
	rs := &dbResultSet{}
	for i := 0; i < 9; i++ {
		rs.Columns = append(rs.Columns, values[i%len(values)][:min(40, len(values[i%len(values)]))]+fmt.Sprint(i))
	}
	for r := 0; r < 30; r++ {
		row := make([]*string, 9)
		for c := range row {
			if (r+c)%5 != 4 {
				row[c] = &values[(r+c)%len(values)]
			}
		}
		rs.Rows = append(rs.Rows, row)
	}
	rs.Rows = append(rs.Rows, []*string{&values[0]}, nil) // rows shorter than the columns
	return rs
}

func TestDatabaseFramesFitThePane(t *testing.T) {
	name := "bad\x1b[41m\u202eapp" + strings.Repeat("名", 60)
	states := map[string]func(v *dbViewer){
		"apps":      func(v *dbViewer) { v.focus = dbApps },
		"no app":    func(v *dbViewer) { v.appID = "" },
		"error":     func(v *dbViewer) { v.result, v.tables, v.err = nil, nil, strings.Repeat("失敗 \x1b[7m", 200) },
		"loading":   func(v *dbViewer) { v.result, v.reading = nil, true },
		"no table":  func(v *dbViewer) { v.result, v.tables, v.table = nil, nil, -1 },
		"no column": func(v *dbViewer) { v.result = &dbResultSet{} },
		"grid":      func(v *dbViewer) { v.cursor, v.leftCol = 7, 3 },
		"grid error": func(v *dbViewer) {
			v.err = strings.Repeat("x", 500) + " " + strings.Repeat("語", 300)
		},
		"query":     func(v *dbViewer) { v.table = -1 },
		"fields":    func(v *dbViewer) { v.cursor, v.detail = 3, true },
		"json":      func(v *dbViewer) { v.cursor, v.detail, v.tab, v.detailTop = 6, true, dbTabJSON, 4 },
		"short row": func(v *dbViewer) { v.cursor, v.detail = 30, true },
		"empty row": func(v *dbViewer) { v.cursor, v.detail, v.tab = 31, true, dbTabJSON },
		"editor": func(v *dbViewer) {
			v.focus = dbEditor
			v.sql.set("a\nb\u0085\u202e\nc\nd " + strings.Repeat("長", 400))
		},
		"empty box": func(v *dbViewer) { v.focus = dbEditor; v.sql.set("") },
		"past bounds": func(v *dbViewer) {
			v.cursor, v.top, v.leftCol, v.selectedDB, v.table, v.detail = 900, 900, 900, 7, 9, true
		},
		"selection": func(v *dbViewer) {
			v.detail, v.dsel = true, detailSel{on: true, line0: 0, col0: 3, line1: 40, col1: 1 << 20}
		},
	}
	var names []string
	for state := range states {
		names = append(names, state)
	}
	sort.Strings(names)
	for _, state := range names {
		v, _ := openedDBViewer(t)
		v.apps.apps = append(v.apps.apps, appEntry{ID: name, Name: &name, IsUserApp: true})
		v.appID = name
		v.device.Model = name
		v.databases = []remoteDB{{Name: name, Path: name}, {}}
		v.tables = []dbTable{{Name: name, RowCount: 1 << 40}, {Name: "", RowCount: -1}}
		v.setResult(dbNasty())
		states[state](v)
		for rows := 1; rows <= 60; rows += 1 + rows/4 {
			for cols := 1; cols <= 200; cols += 1 + cols/6 {
				frame := v.screenRows(rows, cols)
				checkWidths(t, fmt.Sprintf("%s at %dx%d", state, rows, cols), frame, rows, cols)
				for i, row := range frame {
					plain := sgr.ReplaceAllString(row, "")
					if strings.ContainsAny(plain, "\x1b\r\n\t\u0085\u009b\u202e\u2066") {
						t.Fatalf("%s at %dx%d: row %d carries a control character: %q", state, rows, cols, i, plain)
					}
				}
				// The popups over it, and every key and click the pane takes.
				for _, open := range []func(){v.openDBMenu, v.openTableMenu} {
					open()
					if v.menu != nil {
						if box := v.menu.box(rows, cols); len(box) > rows || (len(box) > 0 && (plainWidth(box[0]) > cols || v.menu.left < 1 || v.menu.top < 1)) {
							t.Fatalf("%s at %dx%d: the menu is %d rows of %d cells at %d,%d", state, rows, cols, len(box), plainWidth(box[0]), v.menu.left, v.menu.top)
						}
					}
					v.menu, v.focus = nil, dbGrid
				}
				if box := keysBox(v.helpKeys(), rows, cols); len(box) > rows || (len(box) > 0 && plainWidth(box[0]) > cols) {
					t.Fatalf("%s at %dx%d: the keys popup doesn't fit", state, rows, cols)
				}
				states[state](v)
			}
		}
	}

	// At the sizes a pane really has, the rows fit as they are built, without the last cut.
	v, _ := openedDBViewer(t)
	v.setResult(dbNasty())
	for _, detail := range []bool{false, true} {
		v.detail = detail
		for _, size := range [][2]int{{24, 80}, {30, 100}, {40, 160}, {60, 200}, {12, 50}, {8, 30}, {50, 61}, {20, 44}} {
			checkWidths(t, fmt.Sprintf("built at %dx%d (detail %v)", size[0], size[1], detail), v.frame(size[0], size[1]), size[0], size[1])
		}
	}
}

// Keys and clicks anywhere, in any state and at any size, are taken without a panic.
func TestDatabaseInputNeverPanics(t *testing.T) {
	captureClipboard(t)
	keys := []string{"\r", "\x1b", "j", "k", "h", "l", "g", "G", "\t", "\x1b[Z", "1", "2", "a", "d", "t", "r", "s", "/", "[", "]", "p", "n", "C", "?",
		"\x1b[A", "\x1b[B", "\x1b[C", "\x1b[D", "\x1b[H", "\x1b[F", "\x1b[5~", "\x1b[6~", "\x12", "\x1b[13;9u", "\x18", "\x01", "\x7f", "x", "\x1b\r", "\x1b[99;9u"}
	for _, size := range [][2]int{{1, 1}, {2, 3}, {5, 12}, {12, 40}, {24, 80}, {60, 200}} {
		v, fake := openedDBViewer(t)
		v.setResult(dbNasty())
		for round := 0; round < 3; round++ {
			for i, key := range keys {
				v.handleKey([]byte(key))
				v.screenRows(size[0], size[1])
				for _, button := range []int{0, 2, 64, 65, 66, 67, 68, 69, 0 | mouseDrag, 3} {
					x, y := 1+(i*7+button)%size[1], 1+(i*3+round)%size[0]
					v.mouse(mouseEvent{button: button, x: x, y: y, press: true})
					v.mouse(mouseEvent{button: button, x: x + 1, y: y, press: false})
					v.screenRows(size[0], size[1])
				}
				if v.menu != nil {
					v.menu.box(size[0], size[1])
				}
			}
			// The next round with no result, then with nothing at all.
			if round == 0 {
				v.result = nil
			} else {
				fake.errs["database.rows"], fake.errs["database.pull"] = "failed", "failed"
				v.databases, v.tables, v.selectedDB, v.table = nil, nil, -1, -1
			}
		}
	}
}

func TestDatabaseDeviceOption(t *testing.T) {
	titles := func(d device) []string {
		var out []string
		for _, option := range optionsFor(d, modeAgent) {
			out = append(out, option.title)
		}
		return out
	}
	for platform, want := range map[string][]string{
		"android":      {"Start Logcat", "Inspect Network (Agent HTTP)", "Browse Database"},
		"iosSimulator": {"Start Logcat", "Inspect Network (Agent HTTP)", "Browse Database"},
		"iosDevice":    {"Start Logcat", "Browse Database"},
	} {
		if got := titles(device{ID: "d", Platform: platform, State: "connected"}); !reflect.DeepEqual(got, want) {
			t.Errorf("%s offers %v, want %v", platform, got, want)
		}
	}
	options := optionsFor(device{Platform: "android"}, modeAgent)
	if last := options[len(options)-1]; last.entrypoint != "database" || last.tab != "Jaca database - " {
		t.Errorf("the database option is %+v", last)
	}
	if got := dbTableQuery(`a"b`); got != `SELECT * FROM "a""b"` {
		t.Errorf("the table's statement: %s", got)
	}
}

func strPtr(s string) *string { return &s }

// The values are checked against what the app writes: Swift's Int and Double round trips for
// a plain value, and JSONSerialization's pretty printing (read off Foundation itself) for a
// value that is a JSON object or array.
func TestDatabaseJSONValue(t *testing.T) {
	nested := func(foundation string) string { return strings.ReplaceAll(foundation, "\n", "\n  ") }
	for _, c := range []struct{ value, want string }{
		// Integers and doubles stay unquoted when their text round-trips.
		{"1", `1`}, {"0", `0`}, {"-42", `-42`}, {"9223372036854775807", `9223372036854775807`},
		{"1.0", `1.0`}, {"1.5", `1.5`}, {"-0.25", `-0.25`}, {"0.1", `0.1`}, {"100000.0", `100000.0`}, {"0.0001", `0.0001`},
		{"0.0", `0.0`}, {"-0.0", `-0.0`}, {"1e-05", `1e-05`}, {"1.5e-07", `1.5e-07`}, {"1e+20", `1e+20`},
		{"1.7976931348623157e+308", `1.7976931348623157e+308`}, {"5e-324", `5e-324`}, {"nan", `nan`}, {"inf", `inf`}, {"-inf", `-inf`},
		// Anything else is a string.
		{"01", `"01"`}, {"1e5", `"1e5"`}, {"1E5", `"1E5"`}, {"+1", `"+1"`}, {"-0", `"-0"`}, {" 1", `" 1"`}, {"1 ", `"1 "`},
		{"1.", `"1."`}, {".5", `".5"`}, {"1.50", `"1.50"`}, {"100000", `100000`}, {"1e+5", `"1e+5"`}, {"0x10", `"0x10"`}, {"1_000", `"1_000"`},
		{"9223372036854775808", `"9223372036854775808"`}, {"NaN", `"NaN"`}, {"Infinity", `"Infinity"`}, {"0.00001", `"0.00001"`},
		{"1e+15", `"1e+15"`}, {"1000000000000000.0", `"1000000000000000.0"`}, {"1e+16", `"1e+16"`},
		{"", `""`}, {"text", `"text"`}, {"true", `"true"`}, {"null", `"null"`},
		// The app's escaping: the backslash, the quote, the line break and the tab.
		{"say \"hi\"", `"say \"hi\""`}, {"a\nb", `"a\nb"`}, {"a\tb", `"a\tb"`}, {`C:\dir`, `"C:\\dir"`}, {"a\rb/c", "\"a\rb/c\""},
		{"a\\\"\n\tb", `"a\\\"\n\tb"`}, {"\u00e9\U0001F600", "\"\u00e9\U0001F600\""},
		// Nested JSON: Foundation's output with the app's indent after each of its line breaks.
		{`{"b":1,"a":[1,2,{"x":null}],"c":{}, "d":[], "e":true,"f":false}`,
			nested("{\n  \"a\" : [\n    1,\n    2,\n    {\n      \"x\" : null\n    }\n  ],\n  \"b\" : 1,\n  \"c\" : {\n\n  },\n  \"d\" : [\n\n  ],\n  \"e\" : true,\n  \"f\" : false\n}")},
		{`[]`, "[\n  \n  ]"}, {`{}`, "{\n  \n  }"}, {`[[]]`, nested("[\n  [\n\n  ]\n]")}, {`[{}]`, nested("[\n  {\n\n  }\n]")},
		{` [1]`, nested("[\n  1\n]")}, {"\t[1] \n", nested("[\n  1\n]")}, {`[1,]`, nested("[\n  1\n]")}, {"\r\n[1]", `"` + "\r" + `\n[1]"`},
		{`{"a":2,"b":3,"a":1,}`, nested("{\n  \"a\" : 2,\n  \"b\" : 3\n}")},
		{`["a/b","q\"q","nl\n","\u0001\u001f","\u00e9\ud83d\ude00"]`, nested("[\n  \"a\\/b\",\n  \"q\\\"q\",\n  \"nl\\n\",\n  \"\\u0001\\u001f\",\n  \"\u00e9\U0001F600\"\n]")},
		{`[1.0, 1.5, 0.1, 1e2, 1e20, -0, -0.0, 0.0001, 1E-7, 1.10, 4.35, 1e22, 1e23, 5e-324]`,
			nested("[\n  1,\n  1.5,\n  0.10000000000000001,\n  100,\n  1e+20,\n  0,\n  -0,\n  0.0001,\n  9.9999999999999995e-08,\n  1.1000000000000001,\n  4.3499999999999996,\n  1e+22,\n  9.9999999999999992e+22,\n  4.9406564584124654e-324\n]")},
		{`[12345678901234567890, -9223372036854775809, 123456789012345678901234567890, 3.14159265358979323846, 0.30000000000000000000, 1.23456789012345678901e5, 123456789012345678e3, 12345678901234567e3, 0.000000000000000001, 340282366920938463463374607431768211456, -0.000000000000000000]`,
			nested("[\n  12345678901234567890,\n  -9223372036854775809,\n  123456789012345678901234567890,\n  3.14159265358979323846,\n  0.3,\n  123456.789012345678901,\n  123456789012345678000,\n  1.2345678901234567e+19,\n  0.000000000000000001,\n  340282366920938463463374607431768211450,\n  0\n]")},
		{`{"UserName":1,"userId":2,"user_id":3,"ID":4,"id":5,"createdAt":6,"created_at":7}`,
			nested("{\n  \"created_at\" : 7,\n  \"createdAt\" : 6,\n  \"id\" : 5,\n  \"ID\" : 4,\n  \"user_id\" : 3,\n  \"userId\" : 2,\n  \"UserName\" : 1\n}")},
		// What Foundation doesn't read as an object or an array stays a string.
		{`[1] x`, `"[1] x"`}, {"\n[1]", `"\n[1]"`}, {`[01]`, `"[01]"`}, {`[,1]`, `"[,1]"`}, {`[1,,2]`, `"[1,,2]"`}, {`{a:1}`, `"{a:1}"`},
		{`[NaN]`, `"[NaN]"`}, {`[1e400]`, `"[1e400]"`}, {`["\ud83d"]`, `"[\"\\ud83d\"]"`}, {"[\"a\tb\"]", `"[\"a\tb\"]"`}, {`[1`, `"[1"`},
		{`{"a":1}{}`, `"{\"a\":1}{}"`}, {`[tru]`, `"[tru]"`}, {`[1.]`, `"[1.]"`}, {`[1.0000000000000000000e-110]`, `"[1.0000000000000000000e-110]"`},
		{`"text"`, `"\"text\""`}, {strings.Repeat("[", 514) + strings.Repeat("]", 514), `"` + strings.Repeat("[", 514) + strings.Repeat("]", 514) + `"`},
		{strings.Repeat(`{"a":`, 513) + "1" + strings.Repeat("}", 513), `"` + strings.Repeat(`{\"a\":`, 513) + "1" + strings.Repeat("}", 513) + `"`},
	} {
		if got := dbJSONValue(&c.value, "  "); got != c.want {
			t.Errorf("%q:\n got %q\nwant %q", c.value, got, c.want)
		}
	}
	if got := dbJSONValue(nil, "  "); got != "null" {
		t.Errorf("NULL is %q", got)
	}
	// The deepest nesting Foundation reads: 513 arrays, or 512 objects around a value.
	for _, deep := range []string{strings.Repeat("[", 513) + strings.Repeat("]", 513), strings.Repeat(`{"a":`, 512) + "1" + strings.Repeat("}", 512)} {
		if got := dbJSONValue(&deep, "  "); strings.HasPrefix(got, `"`) {
			t.Errorf("%.20s… was not embedded", deep)
		}
	}
}

func TestDatabaseRowJSON(t *testing.T) {
	columns := []string{"z", "a", `q"uote`, "nested", "none"}
	row := []*string{strPtr("1"), strPtr("x"), strPtr("1.0"), strPtr(`{"k":[]}`), nil}
	// The app indents the nested value by putting two spaces after each of its line breaks,
	// the one of an empty array's blank line too.
	want := "{\n  \"z\": 1,\n  \"a\": \"x\",\n  \"q\\\"uote\": 1.0,\n  \"nested\": {\n    \"k\" : [\n  \n    ]\n  },\n  \"none\": null\n}"
	if got := dbRowJSON(columns, row); got != want {
		t.Errorf("got:\n%s\nwant:\n%s", got, want)
	}
	if got := dbRowJSON(nil, nil); got != "{\n}" {
		t.Errorf("no columns: %q", got)
	}
	// A row shorter than its columns ends where it ends; one longer has no name for the rest.
	if got := dbRowJSON(columns, row[:1]); got != "{\n  \"z\": 1\n}" {
		t.Errorf("a short row: %q", got)
	}
	if got := dbRowJSON(columns[:1], row); got != "{\n  \"z\": 1\n}" {
		t.Errorf("a long row: %q", got)
	}
}

// The order JSONSerialization's .sortedKeys gave for these keys.
func TestDatabaseJSONKeyOrder(t *testing.T) {
	for _, want := range [][]string{
		{"", " ", "_", "1", "2", "10", "a", "A", "a2", "a9", "a10", "ab", "aB", "Ab", "b", "B", "e", "é", "z", "Z"},
		strings.Split(" _-,;:!?.'\"()[]{}@*/\\&#%`^+<=>|~$0123456789aAbBcCyYzZ", ""),
		{"-1", "-2", "😀", "1", "01", "001", "1.5", "1.10", "1a", "1A", "ä", "a a", "a_a", "a-a", "a.a", "a1", "a01", "A1", "aa", "ad", "ae", "Æ", "af",
			"e", "E", "é", "É", "ea", "éa", "ss", "ß", "st", "x1.5", "x1.10", "zz", "日本"},
		{"created_at", "createdAt", "id", "ID", "user_id", "userId", "UserName"},
		{"a", "A", "á", "ä", "Ä", "a b", "a1", "ä1", "ab", "Ab", "äb", "b"},
		{"x 9", "x-9", "x9", "x09", "X9", "x9.5", "x9a", "x10", "x10a"},
	} {
		got := append([]string(nil), want...)
		sort.Sort(sort.Reverse(sort.StringSlice(got)))
		sort.SliceStable(got, func(i, j int) bool { return foundationKeyLess(got[i], got[j]) })
		if !reflect.DeepEqual(got, want) {
			t.Errorf("sorted:\n got %q\nwant %q", got, want)
		}
	}
}

func TestDatabaseCellText(t *testing.T) {
	for _, c := range []struct {
		value string
		w     int
		want  string
	}{
		{"short", 8, "short   "}, {"exactly8", 8, "exactly8"}, {"more than eight", 8, "more th…"}, {"", 3, "   "},
		{"a\tb\nc", 10, "a    bc   "}, {"\x1b[31mred", 5, "red  "}, {"日本語日本語", 5, "日本…"}, {"日", 1, "…"}, {"x", 0, ""},
		{strings.Repeat("\x1b[0m", 4000) + "end", 6, "…     "},
	} {
		if got := dbCellText(c.value, c.w); got != c.want || cellWidth(got) != max(0, c.w) {
			t.Errorf("%q in %d cells: %q", c.value[:min(len(c.value), 20)], c.w, got)
		}
	}
	// A huge value is not read past its start.
	huge := strings.Repeat("x", 10000)
	if got := dbCellText(huge, 24); got != strings.Repeat("x", 23)+"…" {
		t.Errorf("a 10,000-character cell: %q", got)
	}
}
