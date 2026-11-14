package main

import (
	"encoding/json"
	"errors"
	"reflect"
	"strings"
	"testing"
	"time"
)

// testNetViewer is a viewer on a pane that has quit (posted results are dropped), holding three
// captured requests and one saved rule that matches the second.
func testNetViewer(t *testing.T) *netViewer {
	t.Helper()
	t.Setenv("JACA_OVERRIDES_DIR", t.TempDir())
	quit := &pane{work: make(chan func()), done: make(chan struct{})}
	close(quit.done)
	v := &netViewer{p: quit, device: device{ID: "emulator-5554", Platform: "android", Model: "Pixel 8"}, id: newUUID(),
		index: map[string]int{}, bodies: map[string]*netBodies{}, bodyFinal: map[string]bool{}, fetching: map[string]bool{}, removed: map[string]bool{}, mode: modeAgent, opened: true}
	var txns []netTransaction
	if err := json.Unmarshal([]byte(`[
		{"id":"A","method":"GET","url":"https://api.example.com/users/42?expand=1","host":"api.example.com","scheme":"https",
		 "startedAt":"2026-10-06T12:00:01.250Z","finishedAt":"2026-10-06T12:00:01.480Z","responseReceivedAt":"2026-10-06T12:00:01.470Z",
		 "statusCode":200,"responseContentType":"application/json","requestBytes":0,"responseBytes":17,
		 "requestHeaders":[{"name":"Accept","value":"application/json"}],
		 "responseHeaders":[{"name":"Content-Type","value":"application/json"},{"name":"X-Jaca-App","value":"hidden"}],"httpStack":"okhttp3"},
		{"id":"B","method":"POST","url":"https://auth.example.com/login","host":"auth.example.com","scheme":"https",
		 "startedAt":"2026-10-06T12:00:02.000Z","finishedAt":"2026-10-06T12:00:02.100Z","statusCode":401,"requestBytes":12,"responseBytes":0},
		{"id":"C","method":"GET","url":"https://cdn.example.com/a.png","host":"cdn.example.com","scheme":"https",
		 "startedAt":"2026-10-06T12:00:03.000Z","requestBytes":0,"responseBytes":0}
	]`), &txns); err != nil {
		t.Fatal(err)
	}
	v.upsert(txns)
	rule := newOverrideRule()
	rule.Name, rule.Matcher.Pattern, rule.RoutedHosts = "Login stub", "https://auth.example.com/login", []string{"auth.example.com"}
	v.setOverrides(overridesState{Rules: []overrideRule{rule}, MasterEnabled: true, HitCounts: map[string]int{rule.ID: 3}})
	v.state = netState{IsRunning: true, HasRunningSource: true, HasSelectedMode: true, TargetPackage: "com.example.app",
		InterceptWired: true, InterceptCapabilities: capDesktopTerminated}
	return v
}

func plainWidth(s string) int { return cellWidth(sgr.ReplaceAllString(s, "")) }

func TestNetListFilterAndSelection(t *testing.T) {
	v := testNetViewer(t)
	if len(v.visible) != 3 {
		t.Fatalf("%d requests visible, want 3", len(v.visible))
	}
	// An update for a known id replaces it in place; the order stays the arrival order.
	v.upsert([]netTransaction{{ID: "C", Method: "GET", URL: "https://cdn.example.com/a.png", Host: "cdn.example.com", StatusCode: intPtr(304)}})
	if len(v.txns) != 3 || v.txns[2].statusText() != "304" {
		t.Errorf("after an update: %d requests, the third reads %q", len(v.txns), v.txns[2].statusText())
	}
	v.filter.set("AUTH")
	v.refilter()
	if len(v.visible) != 1 || v.txns[v.visible[0]].ID != "B" {
		t.Errorf("filter by host kept %v", v.visible)
	}
	v.filter.set("post")
	v.refilter()
	if len(v.visible) != 1 {
		t.Errorf("filter by method kept %d", len(v.visible))
	}
	v.filter.set("")
	v.refilter()
	v.handleKey([]byte("j"))
	v.handleKey([]byte("j"))
	if v.selectedID != "B" {
		t.Errorf("two steps down selected %q, want B", v.selectedID)
	}
	v.handleKey([]byte{'\r'})
	if !v.detail {
		t.Error("Enter didn't open the detail pane")
	}
	v.handleKey([]byte{'\t'})
	if v.tab != tabHeaders {
		t.Errorf("Tab moved to tab %d", v.tab)
	}
	v.handleKey([]byte{0x1b})
	if v.detail {
		t.Error("Esc didn't close the detail pane")
	}
}

func intPtr(n int) *int { return &n }

// Every row of the list and of the detail pane is exactly its column's width, at any size.
func TestNetColumnsFillTheirWidth(t *testing.T) {
	v := testNetViewer(t)
	v.selectedID, v.detail = "A", true
	v.bodies["A"] = &netBodies{Response: []byte(`{"name":"Ada","tags":["x","y"]}`)}
	for w := 1; w <= 160; w += 3 {
		for i, row := range v.listColumn(w, 12) {
			if got := plainWidth(row); got != w {
				t.Fatalf("list row %d is %d cells in a %d-cell column", i, got, w)
			}
		}
		for tab := range netTabs {
			v.tab = tab
			for i, row := range v.detailColumn(w, 12) {
				if got := plainWidth(row); got != w && got != 0 {
					t.Fatalf("detail row %d (tab %d) is %d cells in a %d-cell column", i, tab, got, w)
				}
			}
		}
		for _, row := range v.toolbar(w, 3) {
			if got := plainWidth(row); got > w {
				t.Fatalf("toolbar is %d cells in a %d-cell pane", got, w)
			}
		}
		if got := plainWidth(v.statusBar(w)); got > w {
			t.Fatalf("status bar is %d cells in a %d-cell pane", got, w)
		}
	}
}

func TestNetDetailContent(t *testing.T) {
	v := testNetViewer(t)
	v.selectedID, v.detail = "A", true
	v.bodies["A"] = &netBodies{Response: []byte(`{"b":1,"a":2}`)}
	text := func(tab int) string {
		v.tab = tab
		lines, _ := v.detailLines(v.txns[0], 80)
		return sgr.ReplaceAllString(strings.Join(lines, "\n"), "")
	}
	if got := text(tabOverview); !strings.Contains(got, "URL") || !strings.Contains(got, "https://api.example.com/users/42?expand=1") || !strings.Contains(got, "RESPONSE SIZE") {
		t.Errorf("overview: %q", got)
	}
	if got := text(tabHeaders); !strings.Contains(got, "REQUEST HEADERS") || !strings.Contains(got, "Copy Response Headers") || strings.Contains(got, "X-Jaca-App") {
		t.Errorf("headers: %q", got)
	}
	if got := text(tabRequest); got != "No body." {
		t.Errorf("request body: %q", got)
	}
	// JSON is shown pretty-printed with sorted keys, under the Copy button.
	if got := text(tabResponse); !strings.HasPrefix(strings.TrimLeft(got, " "), "Copy \n\n{") || strings.Index(got, `"a"`) > strings.Index(got, `"b"`) {
		t.Errorf("response body: %q", got)
	}
	if got := text(tabTiming); !strings.Contains(got, "TIME TO FIRST BYTE") || !strings.Contains(got, "220 ms") {
		t.Errorf("timing: %q", got)
	}
}

// The request menu is the app's: its first item depends on whether a rule already answers it.
func TestNetRowMenu(t *testing.T) {
	v := testNetViewer(t)
	labels := func(id string) []string {
		v.openRowMenu(v.txns[v.index[id]], 5, 5)
		var out []string
		for _, it := range v.menu.items {
			out = append(out, it.label)
		}
		return out
	}
	want := []string{"Override response…", "", "Copy as cURL", "Copy URL", "Copy response body", "", "Filter by this host"}
	if got := labels("A"); !reflect.DeepEqual(got, want) {
		t.Errorf("menu for an unmatched request: %q", got)
	}
	want = []string{"Edit override “Login stub”", "Add another override…", "", "Copy as cURL", "Copy URL", "Copy response body", "", "Filter by this host"}
	if got := labels("B"); !reflect.DeepEqual(got, want) {
		t.Errorf("menu for a matched request: %q", got)
	}
	v.menu.items[len(v.menu.items)-1].act()
	if v.filter.String() != "auth.example.com" || len(v.visible) != 1 {
		t.Errorf("Filter by this host left filter %q, %d visible", v.filter.String(), len(v.visible))
	}
	if b := v.badge(v.txns[1]); b.kind != "willApply" || b.text != "Login stub" {
		t.Errorf("badge for a matched request: %+v", b)
	}
	if b := v.badge(v.txns[0]); b.kind != "" {
		t.Errorf("badge for an unmatched request: %+v", b)
	}
}

// Shift+O on a request opens the editor filled from it, and saving builds the rule the app would.
func TestOverrideARequest(t *testing.T) {
	v := testNetViewer(t)
	v.selectedID = "A"
	v.bodies["A"] = &netBodies{Response: []byte(`{"name":"Ada"}`)}
	v.handleKey([]byte("O"))
	d := v.ovui.draft
	if v.focus != netEditor || d == nil || !d.isNew {
		t.Fatalf("Shift+O left focus %d, draft %v", v.focus, d)
	}
	if d.name.String() != "GET 42" || d.match.String() != "https://api.example.com/users/42" || !d.methods["GET"] || !d.respond || d.status.String() != "200" {
		t.Errorf("seeded draft: name %q match %q methods %v respond %v status %q", d.name.String(), d.match.String(), d.methods, d.respond, d.status.String())
	}
	if !strings.Contains(d.body.String(), `"name": "Ada"`) {
		t.Errorf("seeded body %q", d.body.String())
	}
	if d.blocked() != "" {
		t.Errorf("a seeded rule can't be saved: %q", d.blocked())
	}
	rule, err := d.build()
	if err != nil {
		t.Fatal(err)
	}
	if rule.Action.Kind != "respond" || rule.Action.Respond.StatusCode != 200 || !reflect.DeepEqual(rule.RoutedHosts, []string{"api.example.com"}) ||
		!reflect.DeepEqual(rule.Matcher.Methods, []string{"GET"}) || rule.Action.Respond.Body.Kind != "inline" {
		t.Errorf("built rule: %+v", rule)
	}
	// On a request a rule already answers, Shift+O edits that rule.
	v.closeEditor()
	v.selectedID = "B"
	v.handleKey([]byte("O"))
	if d := v.ovui.draft; d == nil || d.isNew || d.name.String() != "Login stub" {
		t.Errorf("Shift+O on a matched request opened %+v", d)
	}
}

func TestRuleDraftValidationAndAction(t *testing.T) {
	v := testNetViewer(t)
	v.openEditor(blankRule(""), true, "")
	d := v.ovui.draft
	if got := d.blocked(); got != "Enter a URL or pattern to match." {
		t.Errorf("blank rule: %q", got)
	}
	d.match.set("https://*.example.com/v1/**")
	if got := d.blocked(); got != "Add at least one host to route." {
		t.Errorf("a pattern with no literal host: %q", got)
	}
	d.hosts.set(" API.example.com, , auth.example.com ")
	d.sync = routedHostsAfterUserEdit(d.parsedHosts())
	if got := d.routedHosts(); d.blocked() != "" || !reflect.DeepEqual(got, []string{"api.example.com", "auth.example.com"}) {
		t.Errorf("typed hosts: %v, blocked %q", got, d.blocked())
	}
	d.kind = "regex"
	d.match.set("https://api\\.example\\.com/(")
	if got := d.blocked(); got != "Fix the pattern to save." {
		t.Errorf("a broken regex: %q", got)
	}
	// Switching a fresh "Don't send" rule to "Send and override" drops its untouched defaults, so
	// the real response's status and headers show through, and merges headers.
	v.openEditor(blankRule("api.example.com"), true, "")
	d = v.ovui.draft
	d.setRespond(false)
	rule, err := d.build()
	if err != nil {
		t.Fatal(err)
	}
	edit := rule.Action.Edit
	if rule.Action.Kind != "editResponse" || edit.StatusCode != nil || len(edit.Headers) != 0 || edit.HeaderMode != "merge" || edit.Body != nil {
		t.Errorf("send-and-override from defaults: %+v", edit)
	}
	// A blank name becomes the pattern; a long body goes to a blob file.
	d.name.set("  ")
	d.setRespond(true)
	d.body.set(strings.Repeat("x", 5000))
	rule, err = d.build()
	if err != nil {
		t.Fatal(err)
	}
	if rule.Name != "https://api.example.com/" || rule.Action.Respond.Body.Kind != "blob" {
		t.Errorf("name %q, body kind %q", rule.Name, rule.Action.Respond.Body.Kind)
	}
	if text, _ := loadBodyText(rule.Action.Respond.Body); len(text) != 5000 {
		t.Errorf("the blob holds %d bytes", len(text))
	}
}

// The override popups keep one width on every row and fit the pane.
func TestOverridePopupsFit(t *testing.T) {
	v := testNetViewer(t)
	check := func(name string) {
		for _, size := range [][2]int{{40, 160}, {30, 100}, {24, 80}, {60, 220}} {
			box, _, _ := v.overridesBox(size[0], size[1])
			if len(box) == 0 {
				t.Errorf("%s: no popup at %dx%d", name, size[0], size[1])
			}
			if len(box) > size[0] {
				t.Errorf("%s: %d rows in a %d-row pane", name, len(box), size[0])
			}
			for i, row := range box {
				if w := plainWidth(row); w != plainWidth(box[0]) || w > size[1] {
					t.Errorf("%s at %dx%d: row %d is %d cells, the border %d", name, size[0], size[1], i, w, plainWidth(box[0]))
				}
			}
		}
	}
	v.openOverridesList()
	check("list")
	if got := sgr.ReplaceAllString(strings.Join(v.listBox(40, 160).rows, "\n"), ""); !strings.Contains(got, "Login stub") || !strings.Contains(got, "3×") {
		t.Errorf("the list doesn't show the rule and its hit count: %q", got)
	}
	v.openEditor(v.overrides.Rules[0], false, "")
	check("editor")
	v.ovui.draft.headersTab = true
	check("editor headers")
}

func TestTextArea(t *testing.T) {
	var a textArea
	a.set("ab\ncd")
	steps := []struct {
		key  string
		want string
	}{
		{"X", "Xab\ncd"},
		{"\x1b[B", "Xab\ncd"},
		{"\x1b[F", "Xab\ncd"},
		{"!", "Xab\ncd!"},
		{"\r", "Xab\ncd!\n"},
		{"e\nf", "Xab\ncd!\ne\nf"},
		{"\x7f", "Xab\ncd!\ne\n"},
		{"\x7f", "Xab\ncd!\ne"},
		{"\x1b[H", "Xab\ncd!\ne"},
		{"\x7f", "Xab\ncd!e"},
		{"\x1b[3~", "Xab\ncd!"},
	}
	for i, s := range steps {
		a.handle([]byte(s.key), 5)
		if got := a.String(); got != s.want {
			t.Fatalf("step %d (%q): %q, want %q", i, s.key, got, s.want)
		}
	}
	for _, row := range a.view(4, 3, true) {
		if w := plainWidth(row); w != 4 {
			t.Errorf("a view row is %d cells, want 4", w)
		}
	}
}

// Hosts that came from the pattern don't outlive it: changing the pattern to one that names no
// host asks for hosts again, as the app does.
func TestDraftHostsFollowThePattern(t *testing.T) {
	v := testNetViewer(t)
	v.openEditor(blankRule("api.a.com"), true, "")
	d := v.ovui.draft
	if got := d.routedHosts(); !reflect.DeepEqual(got, []string{"api.a.com"}) {
		t.Fatalf("a seeded rule routes %v", got)
	}
	d.stop = editorStop{kind: "match"}
	for range d.match.String() {
		v.editorKey([]byte{0x7f})
	}
	for _, r := range "https://*.b.com/v1/**" {
		v.editorKey([]byte(string(r)))
	}
	if got := d.blocked(); len(d.routedHosts()) != 0 || got != "Add at least one host to route." {
		t.Errorf("after the pattern lost its host: hosts %v, blocked %q", d.routedHosts(), got)
	}
	d.stop = editorStop{kind: "hosts"}
	for _, r := range "API.b.com" {
		v.editorKey([]byte(string(r)))
	}
	if got := d.routedHosts(); d.blocked() != "" || !reflect.DeepEqual(got, []string{"api.b.com"}) {
		t.Errorf("typed hosts: %v, blocked %q", got, d.blocked())
	}
	// A regex the app's engine may accept and Go's doesn't is not blocked from saving.
	d.kind = "regex"
	d.match.set(`https://api\.b\.com/(?!v1).*`)
	if got := d.blocked(); got != "" {
		t.Errorf("an ICU-only regex is blocked: %q", got)
	}
}

// Bodies fetched while a request was in flight are fetched again once it has finished.
func TestBodiesFetchedInFlightAreNotFinal(t *testing.T) {
	v := testNetViewer(t)
	txn := netTransaction{ID: "C", BodiesEvicted: true}
	v.bodies["C"] = &netBodies{Request: []byte("q")}
	if _, ok := v.heldBodies(txn); ok {
		t.Error("bodies fetched before the response count as all there is")
	}
	v.bodyFinal["C"] = true
	if held, ok := v.heldBodies(txn); !ok || string(held.Request) != "q" {
		t.Error("bodies fetched after the request finished aren't served from the cache")
	}
	if _, ok := v.heldBodies(netTransaction{ID: "D"}); !ok {
		t.Error("a request with no bodies still wants a fetch")
	}
}

// A pane too small to draw a popup doesn't let it be edited or saved unseen.
func TestHiddenPopupTakesNoInput(t *testing.T) {
	v := testNetViewer(t)
	v.openEditor(blankRule("api.a.com"), true, "")
	if box, _, _ := v.overridesBox(10, 50); box != nil || !v.ovui.hidden {
		t.Fatal("the editor drew in a 10x50 pane, or isn't marked hidden")
	}
	v.editorKey([]byte("x"))
	v.overridesKey([]byte("x"))
	if got := v.ovui.draft.name.String(); got != "x" && got != "" {
		t.Errorf("unexpected name %q", got)
	}
	v.ovui.draft.name.set("")
	v.overridesKey([]byte("y"))
	if v.ovui.draft.name.String() != "" {
		t.Error("a key edited a popup that isn't drawn")
	}
	v.overridesKey([]byte{0x1b})
	if v.focus != netList {
		t.Error("Esc didn't close the hidden popup")
	}
}

// The timeline strip is the pane's width, and dragging across it filters the list to the
// requests in that time range; a plain click clears the range.
func TestTimelineRange(t *testing.T) {
	v := testNetViewer(t)
	const cols = 101
	strip := v.timeline(cols)
	if len(strip) != timelineLanes {
		t.Fatalf("the timeline has %d rows", len(strip))
	}
	for i, row := range strip {
		if w := plainWidth(row); w != cols {
			t.Errorf("timeline row %d is %d cells, want %d", i, w, cols)
		}
	}
	v.timelineTop, v.timelineCols = 5, cols
	// The requests start at 1.25s, 2.0s and 3.0s: the first half of the strip holds two of them.
	v.mouse(mouseEvent{button: 0, x: 1, y: 5, press: true})
	v.mouse(mouseEvent{button: mouseDrag, x: 50, y: 6, press: true})
	v.mouse(mouseEvent{button: 0, x: 50, y: 6, press: false})
	if !v.rangeSet || len(v.visible) != 2 {
		t.Fatalf("a drag over the first half kept %d requests (range set: %v)", len(v.visible), v.rangeSet)
	}
	if w := plainWidth(v.timeline(cols)[0]); w != cols {
		t.Errorf("with a range, the first row is %d cells", w)
	}
	v.mouse(mouseEvent{button: 0, x: 30, y: 5, press: true})
	v.mouse(mouseEvent{button: 0, x: 30, y: 5, press: false})
	if v.rangeSet || len(v.visible) != 3 {
		t.Errorf("a plain click left the range set (%v) and %d requests", v.rangeSet, len(v.visible))
	}
}

// Backspace deletes the selected request from the list for good: a later update for it is ignored.
func TestDeleteRequest(t *testing.T) {
	v := testNetViewer(t)
	v.selectRow(1)
	v.handleKey([]byte{0x7f})
	if len(v.txns) != 2 || v.selectedID != "C" {
		t.Fatalf("after Backspace: %d requests, selected %q", len(v.txns), v.selectedID)
	}
	v.upsert([]netTransaction{{ID: "B", Method: "POST", URL: "https://auth.example.com/login", Host: "auth.example.com"}})
	if len(v.txns) != 2 {
		t.Error("an update brought the deleted request back")
	}
	v.handleKey([]byte{0x7f})
	v.handleKey([]byte{0x7f})
	v.handleKey([]byte{0x7f}) // nothing left: no crash
	if len(v.txns) != 0 || v.detail {
		t.Errorf("after deleting everything: %d requests, detail %v", len(v.txns), v.detail)
	}
}

// Ctrl+Z undoes the body edit a step at a time (a run of typing is one step) and Ctrl+Y redoes.
func TestTextAreaUndo(t *testing.T) {
	var a textArea
	a.set("{}")
	undo, redo := []byte{0x1a}, []byte{0x19}
	if a.handle(undo, 5) {
		t.Error("undo with no history changed the text")
	}
	for _, r := range "abc" {
		a.handle([]byte(string(r)), 5)
	}
	a.handle([]byte{'\r'}, 5)
	a.handle([]byte("pasted text"), 5)
	a.handle([]byte{0x7f}, 5)
	a.handle([]byte{0x7f}, 5)
	want := []string{"abc\npasted text{}", "abc\n{}", "abc{}", "{}"}
	if got := a.String(); got != "abc\npasted te{}" {
		t.Fatalf("after the edits: %q", got)
	}
	for i, w := range want {
		if !a.handle(undo, 5) || a.String() != w {
			t.Fatalf("undo %d: %q, want %q", i+1, a.String(), w)
		}
	}
	if a.handle(undo, 5) {
		t.Error("undo went past the opened text")
	}
	if !a.handle(redo, 5) || a.String() != "abc{}" {
		t.Errorf("redo: %q", a.String())
	}
	// A new edit drops what could be redone; Format is one step.
	a.handle([]byte("!"), 5)
	if a.handle(redo, 5) {
		t.Error("redo survived a new edit")
	}
	a.replace("formatted")
	a.handle(undo, 5)
	if got := a.String(); got != "abc!{}" {
		t.Errorf("undo after a replace: %q", got)
	}
	// The Kitty-protocol form of ⌘Z undoes too.
	if !a.handle([]byte("\x1b[122;9u"), 5) || a.String() != "abc{}" {
		t.Errorf("⌘Z as a Kitty key: %q", a.String())
	}
}

// Shift+Down and Shift+Up select a run of requests, and Backspace deletes the run.
func TestSelectAndDeleteSeveral(t *testing.T) {
	v := testNetViewer(t)
	v.selectRow(0)
	v.handleKey([]byte("\x1b[1;2B"))
	if first, last, ok := v.selection(); !ok || first != 0 || last != 1 || v.selectedID != "B" {
		t.Fatalf("Shift+Down selected rows %d..%d, cursor %q", first, last, v.selectedID)
	}
	// A plain move goes back to one selected request.
	v.handleKey([]byte("j"))
	if first, last, _ := v.selection(); first != 2 || last != 2 {
		t.Errorf("a plain move left rows %d..%d selected", first, last)
	}
	v.handleKey([]byte("\x1b[1;2A"))
	if first, last, _ := v.selection(); first != 1 || last != 2 {
		t.Errorf("Shift+Up selected rows %d..%d, want 1..2", first, last)
	}
	v.handleKey([]byte{0x7f})
	if len(v.txns) != 1 || v.txns[0].ID != "A" || v.selectedID != "A" {
		t.Errorf("after deleting two: %d requests, selected %q", len(v.txns), v.selectedID)
	}
	// Shift+PgDn from the first row selects to the end.
	w := testNetViewer(t)
	w.selectRow(0)
	w.listRows = 10
	w.handleKey([]byte("\x1b[6;2~"))
	if first, last, _ := w.selection(); first != 0 || last != 2 {
		t.Errorf("Shift+PgDn selected rows %d..%d, want 0..2", first, last)
	}
}

// Shift with a movement key selects in the body; typing or deleting replaces the selection.
func TestTextAreaSelection(t *testing.T) {
	var a textArea
	a.set("hello world\nsecond line")
	key := func(keys ...string) {
		for _, k := range keys {
			a.handle([]byte(k), 5)
		}
	}
	const shiftRight, shiftLeft, shiftDown, shiftEnd, shiftAltRight = "\x1b[1;2C", "\x1b[1;2D", "\x1b[1;2B", "\x1b[1;2F", "\x1b[1;4C"
	key(shiftRight, shiftRight, shiftRight, shiftRight, shiftRight)
	if got := a.selectedText(); got != "hello" {
		t.Fatalf("five Shift+Right selected %q", got)
	}
	key(shiftLeft)
	if got := a.selectedText(); got != "hell" {
		t.Errorf("Shift+Left shrank it to %q", got)
	}
	key("\x7f")
	if got := a.String(); got != "o world\nsecond line" || a.selecting {
		t.Fatalf("Backspace on a selection left %q", got)
	}
	// A selection across lines, replaced by typing.
	key("\x1b[F", shiftDown, shiftEnd)
	if got := a.selectedText(); got != "\nsecond line" {
		t.Errorf("selection across lines: %q", got)
	}
	key("!")
	if got := a.String(); got != "o world!" {
		t.Errorf("typing over a selection left %q", got)
	}
	// Undo brings the replaced text back in one step.
	key("\x1a")
	if got := a.String(); got != "o world\nsecond line" {
		t.Errorf("undo after typing over a selection: %q", got)
	}
	// By word, select all, cut, and a plain move dropping the selection.
	key("\x1b[H", shiftAltRight)
	if got := a.selectedText(); got != "second" {
		t.Errorf("Shift+Alt+Right selected %q", got)
	}
	key("\x1b[C")
	if a.selectedText() != "" {
		t.Error("a plain move kept the selection")
	}
	key("\x01")
	if got := a.cut(); got != "o world\nsecond line" || a.String() != "" {
		t.Errorf("select all then cut: %q, left %q", got, a.String())
	}
	// A click then a drag selects with the mouse.
	a.set("abcdef\nghijkl")
	a.view(20, 5, true)
	a.click(0, 2)
	a.dragTo(1, 3)
	if got := a.selectedText(); got != "cdef\nghi" {
		t.Errorf("drag selected %q", got)
	}
	for _, row := range a.view(8, 3, true) {
		if w := plainWidth(row); w != 8 {
			t.Errorf("a view row with a selection is %d cells, want 8", w)
		}
	}
}

// One-line fields edit at the cursor, which the arrows, Home and End move.
func TestTextInputCursor(t *testing.T) {
	var in textInput
	in.set("hello world")
	for _, step := range []struct{ key, want string }{
		{"\x1b[D", "hello world"}, {"\x1b[D", "hello world"}, {"X", "hello worXld"},
		{"\x1b[H", "hello worXld"}, {">", ">hello worXld"}, {"\x1b[3~", ">ello worXld"},
		{"\x1b[F", ">ello worXld"}, {"\x17", ">ello "}, {"\x1b[1;3D", ">ello "}, {"\x7f", "ello "},
		{"\x15", ""},
	} {
		in.handle([]byte(step.key))
		if got := in.String(); got != step.want {
			t.Fatalf("after %q: %q, want %q", step.key, got, step.want)
		}
	}
	in.set("a long value that does not fit the field")
	for w := 1; w <= 50; w++ {
		for _, pos := range []int{0, 5, len(in.text)} {
			in.pos = pos
			if got := plainWidth(renderField(&in, "placeholder", true, w, sgrUnder)); got != w {
				t.Fatalf("a %d-cell field with the cursor at %d is %d cells", w, pos, got)
			}
		}
	}
}

// In the body Tab indents; Esc hands the keys back to moving between fields, and a second Esc
// closes the editor.
func TestBodyTabAndEscape(t *testing.T) {
	v := testNetViewer(t)
	v.openEditor(blankRule("api.a.com"), true, "")
	d := v.ovui.draft
	d.stop = editorStop{kind: "body"}
	v.editorKey([]byte("{"))
	v.editorKey([]byte{'\r'})
	v.editorKey([]byte{'\t'})
	v.editorKey([]byte("x"))
	if got := d.body.String(); got != "{\n  x" || d.stop.kind != "body" {
		t.Fatalf("Tab in the body: text %q, focus %q", got, d.stop.kind)
	}
	v.editorKey([]byte{0x1b})
	if v.focus != netEditor || !d.bodyNav {
		t.Fatal("Esc in the body closed the editor, or didn't leave the text")
	}
	v.editorKey([]byte("y"))
	if got := d.body.String(); got != "{\n  x" {
		t.Errorf("a key edited the body after Esc: %q", got)
	}
	v.editorKey([]byte{'\t'})
	if d.stop.kind == "body" || d.bodyNav {
		t.Errorf("Tab after Esc left the focus on %q", d.stop.kind)
	}
	// Shift+Tab in the body takes the indent back off; after Esc it moves to the field before.
	d.stop, d.bodyNav = editorStop{kind: "body"}, false
	v.editorKey([]byte("\x1b[Z"))
	if got := d.body.String(); got != "{\nx" || d.stop.kind != "body" {
		t.Errorf("Shift+Tab in the body: text %q, focus %q", got, d.stop.kind)
	}
	v.editorKey([]byte{0x1a}) // undo the outdent
	v.editorKey([]byte{0x1b})
	v.editorKey([]byte("\x1b[Z"))
	if d.stop.kind != "format" {
		t.Errorf("Shift+Tab after Esc went to %q", d.stop.kind)
	}
	// Esc+Tab arriving as one key leaves the body forwards.
	d.stop = editorStop{kind: "body"}
	v.editorKey([]byte("\x1b\t"))
	if d.stop.kind != "enabled" {
		t.Errorf("Esc+Tab from the body went to %q", d.stop.kind)
	}
	// ⌘A, ⌘X as Herdr forwards them: select all, then cut.
	copied := captureClipboard(t)
	d.stop, d.bodyNav = editorStop{kind: "body"}, false
	v.editorKey([]byte("\x1b[97;9u"))
	v.editorKey([]byte("\x1b[120;9u"))
	if got := <-copied; got != "{\n  x" || d.body.String() != "" {
		t.Errorf("⌘A then ⌘X copied %q and left %q", got, d.body.String())
	}
	v.editorKey([]byte{0x1b})
	v.editorKey([]byte{0x1b})
	if v.focus != netList {
		t.Error("a second Esc didn't close the editor")
	}
}

// Tab over several selected lines indents them all, Shift+Tab takes a level off each, and the
// selection stays on the same text.
func TestTextAreaBlockIndent(t *testing.T) {
	var a textArea
	a.set("a\n  b\n c\nd")
	key := func(keys ...string) {
		for _, k := range keys {
			a.handle([]byte(k), 5)
		}
	}
	const shiftDown, shiftTab = "\x1b[1;2B", "\x1b[Z"
	key(shiftDown, shiftDown, shiftDown) // lines 1 to 3, reaching only the start of the fourth
	key("\t")
	if got := a.String(); got != "  a\n    b\n   c\nd" {
		t.Fatalf("Tab over three lines: %q", got)
	}
	if got := a.selectedText(); got != "a\n    b\n   c\n" {
		t.Errorf("the selection after indenting: %q", got)
	}
	key(shiftTab)
	if got := a.String(); got != "a\n  b\n c\nd" {
		t.Errorf("Shift+Tab: %q", got)
	}
	key(shiftTab)
	key(shiftTab) // nothing left to take: no change, no undo step
	if got := a.String(); got != "a\nb\nc\nd" {
		t.Errorf("Shift+Tab to the margin: %q", got)
	}
	key("\x1a")
	if got := a.String(); got != "a\n  b\n c\nd" {
		t.Errorf("undo of one outdent: %q", got)
	}
	// With no selection Shift+Tab acts on the cursor's line and keeps the cursor on its text.
	a.set("    key")
	key("\x1b[F", shiftTab, "!")
	if got := a.String(); got != "  key!" {
		t.Errorf("Shift+Tab on the cursor's line: %q", got)
	}
}

// Ctrl+S, and ⌘S as Herdr forwards it, save the rule editor and the Copy format popup.
func TestSaveShortcut(t *testing.T) {
	for _, key := range []string{"\x13", "\x1b[115;9u"} {
		t.Setenv("HOME", t.TempDir())
		editor := newFormatEditor(defaultCopyFormat)
		if got := editor.key([]byte(key)); got != editorSave {
			t.Errorf("%q in the Copy format popup: action %d", key, got)
		}
		v := testNetViewer(t)
		v.p = &pane{work: make(chan func()), done: make(chan struct{})}
		close(v.p.done)
		v.openEditor(blankRule(""), true, "") // nothing to match yet: saving is blocked
		v.editorKey([]byte(key))
		if v.focus != netEditor {
			t.Errorf("%q saved a rule that can't be saved", key)
		}
	}
}

// Text in the detail content is selected by dragging and copied on release; a value that
// wrapped comes back in one piece. A double click copies the whole value, a right click offers
// Copy, and the copy buttons are pressed on their own cells only.
func TestNetDetailSelection(t *testing.T) {
	v := testNetViewer(t)
	setTermSize(t, 30, 120)
	copied := captureClipboard(t)
	v.selectedID, v.detail = "A", true
	v.draw()
	if len(v.detailMeta) == 0 {
		t.Fatal("no detail content drawn")
	}
	line := func(prefix string) int {
		for i, text := range v.detailText {
			if strings.HasPrefix(text, prefix) {
				return i
			}
		}
		t.Fatalf("no detail line starts with %q: %q", prefix, v.detailText)
		return -1
	}
	at := func(line, col int, button int, press bool) mouseEvent {
		return mouseEvent{button: button, x: v.detailX + col, y: v.detailFirst + line - v.detailTop, press: press}
	}
	url, method := line("URL"), line("METHOD")
	x := v.detailMeta[url].valueX

	// A drag from the URL's first cell to the method's value.
	v.mouse(at(url, x, 0, true))
	v.mouse(at(method, v.detailMeta[method].valueX+2, mouseDrag, true))
	v.mouse(at(method, v.detailMeta[method].valueX+2, 0, false))
	got := <-copied
	if !strings.HasPrefix(got, "https://api.example.com/users/42?expand=1") || !strings.HasSuffix(got, "GET") || strings.Count(got, "\n") != 1 {
		t.Errorf("the drag copied %q", got)
	}
	v.draw()

	// A click selects nothing and copies nothing.
	v.mouse(at(url, x+3, 0, true))
	v.mouse(at(url, x+3, 0, false))
	select {
	case text := <-copied:
		t.Fatalf("a click copied %q", text)
	default:
	}
	if v.dsel.on {
		t.Error("a click left a selection")
	}

	// A double click copies the whole value.
	v.lastPress = time.Time{}
	v.mouse(at(method, 1, 0, true))
	v.mouse(at(method, 1, 0, false))
	v.mouse(at(method, 1, 0, true))
	if got := <-copied; got != "GET" {
		t.Errorf("a double click copied %q", got)
	}
	v.mouse(at(method, 1, 0, false))

	// A right click offers Copy for the value under it.
	v.dsel = detailSel{}
	v.mouse(at(url, x+1, 2, true))
	if v.menu == nil || len(v.menu.items) != 1 || v.menu.items[0].label != "Copy" {
		t.Fatalf("right click opened %+v", v.menu)
	}
	v.menu.items[0].act()
	if got := <-copied; got != "https://api.example.com/users/42?expand=1" {
		t.Errorf("Copy copied %q", got)
	}
	v.menu, v.focus = nil, netList

	// The Copy button of a section is pressed on its cells, not on the rest of its line.
	v.setTab(tabHeaders)
	v.draw()
	button := -1
	for i, l := range v.detailMeta {
		if l.act != nil {
			button = i
			break
		}
	}
	if button < 0 {
		t.Fatal("no copy button on the headers tab")
	}
	v.mouse(at(button, 0, 0, true))
	v.mouse(at(button, 0, 0, false))
	select {
	case text := <-copied:
		t.Fatalf("a click beside the button copied %q", text)
	default:
	}
	v.mouse(at(button, v.detailMeta[button].x1-1, 0, true))
	if got := <-copied; !strings.Contains(got, ": ") {
		t.Errorf("the button copied %q", got)
	}
}

// An update of the network.mode topic sets the mode; a name this client doesn't know is ignored.
func TestModeTopic(t *testing.T) {
	v := testNetViewer(t)
	v.handleEvent(event{Topic: "network.mode", Data: json.RawMessage(`{"mode":"mitm","switching":false}`)})
	if v.mode != modeMITM {
		t.Fatalf("mode = %q, want mitm", v.mode)
	}
	v.handleEvent(event{Topic: "network.mode", Data: json.RawMessage(`{"mode":"later","switching":true}`)})
	if v.mode != modeMITM {
		t.Errorf("an unknown mode changed it to %q", v.mode)
	}
	if !reflect.DeepEqual(v.topics()[len(v.topics())-1], "network.mode") {
		t.Errorf("topics %v leave out network.mode", v.topics())
	}
	// The simulator's auto re-attach switch exists in Agent HTTPS debugging only.
	v.device.Platform = "iosSimulator"
	v.state.AttachState = armingState{State: "detached", AppID: "com.example.app"}
	if v.offersAutoReattach() {
		t.Error("MITM mode offers auto re-attach")
	}
	v.handleEvent(event{Topic: "network.mode", Data: json.RawMessage(`{"mode":"agent","switching":false}`)})
	if !v.offersAutoReattach() {
		t.Error("Agent mode doesn't offer auto re-attach")
	}
}

// M opens the two modes; choosing the other one calls network.setMode with its wire name.
func TestModeMenu(t *testing.T) {
	v := testNetViewer(t)
	c, calls := pipeClient(t)
	v.p.c = c
	v.handleKey([]byte("M"))
	if v.focus != netMenu || v.menu == nil || len(v.menu.items) != 2 {
		t.Fatalf("M: focus %v, menu %+v", v.focus, v.menu)
	}
	if v.menu.items[0].label != "Agent HTTPS debugging" || v.menu.items[1].label != "MITM HTTPS debugging" || v.menu.selected != 0 {
		t.Errorf("menu items %q, %q, selected %d", v.menu.items[0].label, v.menu.items[1].label, v.menu.selected)
	}
	v.handleKey([]byte("\x1b[B"))
	v.handleKey([]byte{'\r'})
	got := waitCalls(t, calls, 1)
	if got[0]["method"] != "network.setMode" || !reflect.DeepEqual(got[0]["params"], map[string]any{"mode": "mitm"}) {
		t.Errorf("call: %v", got[0])
	}
	// Choosing the current mode calls nothing.
	v.handleKey([]byte("M"))
	v.handleKey([]byte{'\r'})
	time.Sleep(50 * time.Millisecond)
	if n := len(calls()); n != 1 {
		t.Errorf("the current mode made %d calls", n)
	}
	found := false
	for _, k := range v.helpKeys() {
		found = found || (k[0] == "M" && k[1] == "inspection mode")
	}
	if !found {
		t.Error("the help keys leave out M")
	}
}

// The chooser shows a row for each offered source this client can start. Enter on the device
// proxy selects it with no package; Enter on the agent opens the app list.
func TestChooserRowsByOffered(t *testing.T) {
	v := testNetViewer(t)
	v.txns, v.visible, v.index = nil, nil, map[string]int{}
	v.state = netState{OfferedSourceIDs: []string{"mitm"}}
	if !v.showsChooser() {
		t.Fatal("no chooser")
	}
	v.listTop = 4
	text := strings.Join(stripAll(v.listColumn(100, 20)), "\n")
	if !strings.Contains(text, " Device proxy ") || strings.Contains(text, "Inspect app") ||
		!strings.Contains(text, "Decrypt HTTPS device-wide through a proxy the device is set to trust.") {
		t.Errorf("mitm chooser:\n%s", text)
	}
	if v.transport() != transportMITMProxy {
		t.Errorf("transport before a choice = %q", v.transport())
	}
	c, calls := pipeClient(t)
	v.p.c = c
	v.handleKey([]byte{'\r'})
	got := waitCalls(t, calls, 1)
	if got[0]["method"] != "network.select" || !reflect.DeepEqual(got[0]["params"], map[string]any{"id": v.id, "sourceID": "mitm"}) {
		t.Errorf("Enter on the device proxy: %v", got[0])
	}
	if v.focus == netApps {
		t.Error("the device proxy opened the app list")
	}

	// Both offered: two rows, Down moves to the second, and a click on a row chooses it.
	v.state = netState{OfferedSourceIDs: []string{"agent", "mitm", "companion"}}
	v.chooserRow = 0
	v.chooserHits = nil
	text = strings.Join(stripAll(v.listColumn(100, 30)), "\n")
	if !strings.Contains(text, " Inspect app ") || !strings.Contains(text, " Device proxy ") || len(v.chooserHits) != 2 {
		t.Fatalf("two-row chooser (%d hits):\n%s", len(v.chooserHits), text)
	}
	v.handleKey([]byte("\x1b[B"))
	if v.chooserRow != 1 {
		t.Errorf("Down moved to row %d", v.chooserRow)
	}
	v.handleKey([]byte("\x1b[B"))
	if v.chooserRow != 1 {
		t.Errorf("Down past the end moved to row %d", v.chooserRow)
	}
	v.mouse(mouseEvent{button: 0, x: 4, y: v.chooserHits[0].x0, press: true})
	if v.focus != netApps {
		t.Errorf("a click on Inspect app: focus %v", v.focus)
	}
	v.focus = netList

	// A jacad without offered sources has the agent alone; a device with none shows no rows.
	v.state = netState{}
	if got := v.chooserSources(); !reflect.DeepEqual(got, []string{"agent"}) {
		t.Errorf("old jacad: %v", got)
	}
	v.state = netState{OfferedSourceIDs: []string{}}
	v.chooserHits = nil
	if text := strings.Join(stripAll(v.listColumn(100, 20)), "\n"); strings.Contains(text, "Choose how") || len(v.chooserHits) != 0 {
		t.Errorf("no sources:\n%s", text)
	}
	v.handleKey([]byte{'\r'})
	v.handleKey([]byte("a"))
	if v.focus == netApps {
		t.Error("the app list opened with no agent offered")
	}
}

// p starts a stopped device proxy capture again, with no package.
func TestToggleRestartsDeviceProxy(t *testing.T) {
	v := testNetViewer(t)
	v.state = netState{HasSelectedMode: true, SelectedSourceID: "mitm", OfferedSourceIDs: []string{"mitm"}}
	c, calls := pipeClient(t)
	v.p.c = c
	v.handleKey([]byte("p"))
	got := waitCalls(t, calls, 1)
	if got[0]["method"] != "network.select" || !reflect.DeepEqual(got[0]["params"], map[string]any{"id": v.id, "sourceID": "mitm"}) {
		t.Errorf("p: %v", got[0])
	}
}

// I installs the certificate through jacad, on Android and on the iOS Simulator.
func TestInstallCAKey(t *testing.T) {
	for _, platform := range []string{"android", "iosSimulator"} {
		v := testNetViewer(t)
		v.device.Platform = platform
		v.state = netState{IsRunning: true, SelectedSourceID: "mitm", ProxyNeedsSetup: true}
		c, calls := pipeClient(t)
		v.p.c = c
		v.handleKey([]byte("I"))
		got := waitCalls(t, calls, 1)
		if got[0]["method"] != "network.installCA" || !reflect.DeepEqual(got[0]["params"], map[string]any{"id": v.id}) {
			t.Errorf("%s: I called %v", platform, got[0])
		}
		if v.setup.busy == "" || !v.showsSetupBanner() {
			t.Errorf("%s: no progress in the banner", platform)
		}
		// A second I while the first runs calls nothing.
		v.handleKey([]byte("I"))
		time.Sleep(50 * time.Millisecond)
		if n := len(calls()); n != 1 {
			t.Errorf("%s: %d calls after a second I", platform, n)
		}
	}
	// No certificate to install on a physical iOS device, or for an agent capture with no banner.
	v := testNetViewer(t)
	c, calls := pipeClient(t)
	v.p.c = c
	v.handleKey([]byte("I"))
	v.device.Platform = "iosDevice"
	v.state = netState{SelectedSourceID: "mitm", ProxyNeedsSetup: true}
	v.handleKey([]byte("I"))
	time.Sleep(50 * time.Millisecond)
	if n := len(calls()); n != 0 {
		t.Errorf("%d calls, want none: %v", n, calls())
	}
}

// x dismisses the prompt here and in jacad.
func TestDismissSetupBanner(t *testing.T) {
	v := testNetViewer(t)
	v.state = netState{IsRunning: true, SelectedSourceID: "mitm", ProxyNeedsSetup: true}
	c, calls := pipeClient(t)
	v.p.c = c
	if !v.showsSetupBanner() {
		t.Fatal("no banner")
	}
	v.handleKey([]byte("x"))
	got := waitCalls(t, calls, 1)
	if got[0]["method"] != "network.clearProxyNeedsSetup" || v.showsSetupBanner() {
		t.Errorf("x: %v, banner %v", got[0], v.showsSetupBanner())
	}
	// With the certificate ready there is no prompt.
	v.state = netState{ProxyNeedsSetup: true, CAReady: true}
	if v.showsSetupBanner() {
		t.Error("banner with the certificate ready")
	}
}

// What each network.installCA outcome shows, and the reboot a simulator install offers.
func TestInstallOutcome(t *testing.T) {
	if got := installOutcome(installCAResult{Outcome: "installed"}, nil); got.outcome != "Jaca's certificate is installed in the device's system store." || got.offerReboot || got.failed {
		t.Errorf("installed: %+v", got)
	}
	if got := installOutcome(installCAResult{Outcome: "needsUser"}, nil); !strings.HasPrefix(got.outcome, "Jaca copied its certificate to Download/JacaProxyCA.pem.") {
		t.Errorf("needsUser: %+v", got)
	}
	if got := installOutcome(installCAResult{Outcome: "failed", Message: "Couldn't copy the certificate to the device."}, nil); !got.failed || got.outcome != "Couldn't copy the certificate to the device." {
		t.Errorf("failed: %+v", got)
	}
	if got := installOutcome(installCAResult{}, errors.New("network.installCA: no reply")); !got.failed || got.outcome == "" {
		t.Errorf("call error: %+v", got)
	}
	if got := installOutcome(installCAResult{Outcome: "later"}, nil); got != (setupBanner{}) {
		t.Errorf("unknown outcome: %+v", got)
	}
	sim := installOutcome(installCAResult{Outcome: "installed", RebootAdvised: true}, nil)
	if !sim.offerReboot {
		t.Fatalf("simulator install: %+v", sim)
	}
	v := testNetViewer(t)
	v.device.Platform = "iosSimulator"
	v.setup = sim
	c, calls := pipeClient(t)
	v.p.c = c
	v.handleKey([]byte("B"))
	got := waitCalls(t, calls, 1)
	if got[0]["method"] != "network.rebootSimulator" || !reflect.DeepEqual(got[0]["params"], map[string]any{"id": v.id}) {
		t.Errorf("B: %v", got[0])
	}
}

func stripAll(rows []string) []string {
	out := make([]string, len(rows))
	for i, r := range rows {
		out[i] = stripSGR(r)
	}
	return out
}

// A mode switch reopens the chooser and keeps the old SelectedSourceID. The transport then
// follows the first offered source, not the stale one.
func TestSourceIDIgnoresAStaleSelectionAtTheChooser(t *testing.T) {
	v := testNetViewer(t)
	v.state = netState{HasSelectedMode: false, SelectedSourceID: "agent", OfferedSourceIDs: []string{"mitm"}}
	if got := v.sourceID(); got != "mitm" {
		t.Errorf("sourceID = %q, want mitm", got)
	}
	v.state.HasSelectedMode, v.state.SelectedSourceID = true, "mitm"
	if got := v.sourceID(); got != "mitm" {
		t.Errorf("chosen sourceID = %q, want mitm", got)
	}
}

// R re-attaches a detached agent, so the help lists it only where the agent is offered.
func TestHelpListsRelaunchOnlyForTheSimulatorAgent(t *testing.T) {
	v := testNetViewer(t)
	v.device = device{ID: "SIM-1", Platform: "iosSimulator", Model: "iPhone"}
	has := func() bool {
		for _, k := range v.helpKeys() {
			if k[0] == "R" {
				return true
			}
		}
		return false
	}
	v.state = netState{OfferedSourceIDs: []string{"mitm"}}
	if has() {
		t.Error("the MITM simulator capture lists R")
	}
	v.state = netState{OfferedSourceIDs: []string{"agent"}}
	if !has() {
		t.Error("the agent simulator capture leaves out R")
	}
}
