package main

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"sort"
	"strings"
	"time"
)

// What the keys act on in the network viewer.
type netFocus int

const (
	netList      netFocus = iota // the request list (and the detail beside it)
	netSearch                    // the filter field
	netApps                      // the installed-apps list
	netMenu                      // the request's right-click menu
	netHelp                      // the keys popup
	netOverrides                 // the overrides popup (overridesui.go)
	netEditor                    // the override editor (overridesui.go)
)

// The detail tabs, as in the app's NetworkDetailView.
var netTabs = []string{"Overview", "Headers", "Request", "Response", "Timing"}

const (
	tabOverview = iota
	tabHeaders
	tabRequest
	tabResponse
	tabTiming
)

// netBodies is a request's bodies as fetched with network.body.
type netBodies struct {
	Request  []byte `json:"request"`
	Response []byte `json:"response"`
}

// netViewer is the app's network tab for the in-process agent (NetworkSessionView): the capture
// of one app's requests, a detail pane beside the list, and the response overrides.
type netViewer struct {
	snack  snackbar // "Copied"
	p      *pane
	device device
	back   func() // returns to the picker when the viewer runs in its pane; nil in a tab
	left   bool

	id     string // the capture's id in jacad
	opened bool
	mode   string // the network inspection mode (modeAgent or modeMITM), as jacad last reported it
	// The app's "Re-attach to iOS Simulator apps automatically" setting, as last read or set
	// here. jacad reads it each time it decides whether to relaunch.
	autoReattach bool
	state        netState
	err          string // why the last call failed, as jacad reported it
	saved        string // where the last export went

	txns     []netTransaction
	index    map[string]int // transaction id -> position in txns
	visible  []int          // positions in txns the filter keeps, in arrival order
	clearing bool           // a network.clear is in flight: updates published before it are dropped

	filter     textInput
	selectedID string // the selected request (the cursor), "" for none
	anchorID   string // where a Shift selection started: every request from here to the cursor is selected
	top        int    // the first visible request drawn
	scrolled   bool   // the list was scrolled by hand, so it no longer follows new requests

	detail      bool // the detail pane is open
	detailFocus bool // and has the keys: they scroll it and switch its tabs, and Esc goes back to the list
	tab         int
	bodies      map[string]*netBodies // by transaction id; nil while not fetched
	bodyFinal   map[string]bool       // the bodies were fetched after the request finished
	fetching    map[string]bool
	clears      int             // how many times the list was cleared, to drop replies from before a clear
	removed     map[string]bool // requests deleted from the list here (jacad still holds them)

	// The time range selected on the timeline; the list shows the requests that overlap it.
	rangeSet           bool
	rangeFrom, rangeTo time.Time
	dragging           bool // a drag on the timeline is in progress,
	dragFrom, dragTo   int  // between these columns (1-based)
	timelineTop        int  // the timeline as last drawn: its first screen row (0 when hidden),
	timelineCols       int  // its width,
	clearX             int  // and the column of its clear button (0 when hidden)

	focus netFocus
	hits  []hit
	menu  *popupMenu
	apps  appPicker

	chooserRow  int   // the selected row of the capture chooser
	chooserHits []hit // its rows as last drawn: x0..x1 are the first and last screen row of each

	setup setupBanner

	overrides overridesState
	rules     ruleSet
	ovui      overridesUI

	// The pane as last drawn, for the mouse.
	listTop, listRows, listW int
	detailContent
	tabHits          []hit
	closeX0, closeX1 int
	bannerHits       []boxHit // the banner's buttons: a screen row (1-based) and its columns
	helpX0, helpX1   int
}

// runNetworkPane is the viewer for the device the picker passed in deviceEnv. Opened without
// one, it shows the picker first.
func runNetworkPane() int {
	var d device
	if json.Unmarshal([]byte(os.Getenv(deviceEnv)), &d) != nil || d.ID == "" {
		return runPicker(false)
	}
	c, err := dial()
	if err != nil {
		fmt.Fprintln(os.Stderr, "jaca:", err)
		return 1
	}
	defer c.Close()
	go sendRightClicksToPane()
	return runPane(c, func(p *pane) screen { return newNetViewer(p, d, nil) })
}

func newNetViewer(p *pane, d device, back func()) *netViewer {
	v := &netViewer{p: p, device: d, back: back, id: newUUID(), index: map[string]int{},
		bodies: map[string]*netBodies{}, bodyFinal: map[string]bool{}, fetching: map[string]bool{}, removed: map[string]bool{}, mode: modeAgent}
	v.open()
	return v
}

func (v *netViewer) topics() []string {
	return []string{"net.txns." + v.id, "net.state." + v.id, "overrides.state", "network.mode"}
}

// setMode takes a mode jacad reported. A name this client doesn't know leaves the mode as it was.
func (v *netViewer) setMode(st netModeState) {
	if st.Mode == modeAgent || st.Mode == modeMITM {
		v.mode = st.Mode
	}
}

// refetchMode reads the mode again, after updates of its topic were skipped.
func (v *netViewer) refetchMode() {
	go func() {
		var st netModeState
		if v.p.c.CallTimeout("network.mode", nil, &st, syncTimeout) == nil {
			v.p.post(func() { v.setMode(st) })
		}
	}()
}

// open subscribes, then opens the capture stopped (starting can relaunch the user's app, so that
// waits for the app to be chosen) and reads what it already holds.
func (v *netViewer) open() {
	id, d, topics := v.id, v.device, v.topics()
	go func() {
		c := v.p.c
		var info struct {
			State netState `json:"state"`
		}
		var txns []netTransaction
		var ov overridesState
		err := c.Subscribe(topics...)
		created := false
		if err == nil {
			// The app may have edited the rule library in its own process meanwhile.
			_ = c.CallTimeout("overrides.reload", nil, nil, syncTimeout)
			params := map[string]any{"id": id, "device": d, "autoStart": false}
			if d.isMac() {
				// This Mac has nothing to choose: its capture opens the Chrome window at once.
				params["sourceID"], params["autoStart"] = "browser", true
			}
			err = c.Call("network.open", params, &info)
			created = err == nil
		}
		if created {
			err = c.CallTimeout("network.transactions", map[string]any{"id": id}, &txns, time.Minute)
			_ = c.CallTimeout("overrides.state", nil, &ov, syncTimeout)
		}
		mode := fetchMode(c)
		auto, _, _ := readDefault(autoReattachKey)
		delivered := v.p.post(func() {
			if err != nil {
				v.err = err.Error()
			}
			switch {
			case v.left:
				go v.closeRemote()
			case created:
				// The capture exists even if reading its requests failed: it is this pane's to close.
				v.opened, v.mode, v.state, v.autoReattach = true, mode, info.State, auto == "1"
				v.p.setLive("network.close", id)
				v.setOverrides(ov)
				v.upsert(txns)
			default:
				// network.open may have gone through after the client stopped waiting for it.
				go v.closeRemote()
			}
		})
		if !delivered {
			v.closeRemote()
		}
	}()
}

func (v *netViewer) closeRemote() {
	_ = v.p.c.CallTimeout("events.unsubscribe", map[string]any{"topics": v.topics()}, nil, teardownTimeout)
	_ = v.p.c.CallTimeout("network.close", map[string]any{"id": v.id}, nil, teardownTimeout)
}

// leave closes the capture: left open, the agent stays attached and rules keep diverting the
// app's requests until jacad's orphan reaper runs.
func (v *netViewer) leave(wait bool) {
	v.left = true
	if !v.opened {
		return
	}
	v.opened = false
	v.p.setLive("", "")
	if wait {
		v.closeRemote()
	} else {
		go v.closeRemote()
	}
}

// call runs a capture method off the loop and shows why it failed, if it did.
func (v *netViewer) call(method string, params map[string]any) {
	go func() {
		if err := v.p.c.Call(method, params, nil); err != nil {
			v.p.post(func() { v.err = err.Error() })
		}
	}()
}

func (v *netViewer) handleEvent(ev event) {
	switch ev.Topic {
	case "net.txns." + v.id:
		var batch []netTransaction
		if !v.clearing && json.Unmarshal(ev.Data, &batch) == nil {
			v.upsert(batch)
		}
	case "net.state." + v.id:
		var st netState
		if json.Unmarshal(ev.Data, &st) == nil {
			v.state = st
		}
	case "overrides.state":
		var ov overridesState
		if json.Unmarshal(ev.Data, &ov) == nil {
			v.setOverrides(ov)
		}
	case "network.mode":
		var st netModeState
		if json.Unmarshal(ev.Data, &st) == nil {
			v.setMode(st)
		}
	case "events.dropped":
		var note droppedNote
		if json.Unmarshal(ev.Data, &note) != nil {
			return
		}
		switch note.Topic {
		case "net.txns." + v.id:
			v.resync()
		case "net.state." + v.id:
			// network.open on an open capture returns its state and changes nothing.
			go func() {
				var info struct {
					State netState `json:"state"`
				}
				if v.p.c.CallTimeout("network.open", map[string]any{"id": v.id, "device": v.device, "autoStart": false}, &info, syncTimeout) == nil {
					v.p.post(func() {
						if v.left {
							go v.closeRemote() // the call may have recreated a capture closed meanwhile
							return
						}
						v.state = info.State
					})
				}
			}()
		case "overrides.state":
			go func() {
				var ov overridesState
				if v.p.c.CallTimeout("overrides.state", nil, &ov, syncTimeout) == nil {
					v.p.post(func() { v.setOverrides(ov) })
				}
			}()
		case "network.mode":
			v.refetchMode()
		}
	}
}

// resync reads every request again after updates were skipped.
func (v *netViewer) resync() {
	clears := v.clears
	go func() {
		var txns []netTransaction
		if v.p.c.CallTimeout("network.transactions", map[string]any{"id": v.id}, &txns, time.Minute) == nil {
			v.p.post(func() {
				if !v.clearing && clears == v.clears { // not a reply from before a clear
					v.upsert(txns)
				}
			})
		}
	}()
}

func (v *netViewer) setOverrides(ov overridesState) {
	v.overrides = ov
	// A rule in a group that is off doesn't match, as one that is off itself doesn't.
	v.rules = compileRules(ov.activeRules(), ov.MasterEnabled)
}

// upsert applies request updates: a known id is replaced in place, a new one is appended, so the
// list stays in arrival order.
func (v *netViewer) upsert(batch []netTransaction) {
	for _, t := range batch {
		if v.removed[t.ID] {
			continue
		}
		if i, ok := v.index[t.ID]; ok {
			v.txns[i] = t
			if t.ID == v.selectedID && v.detail {
				v.fetchBodies(t, true, nil) // it may have finished, with a body to show now
			}
			continue
		}
		v.index[t.ID] = len(v.txns)
		v.txns = append(v.txns, t)
	}
	v.refilter()
}

// matchesFilter is NetworkSession's filter: a case-insensitive substring of the URL, the host or
// the method.
func (v *netViewer) matchesFilter(t netTransaction, q string) bool {
	return q == "" || strings.Contains(strings.ToLower(t.URL), q) ||
		strings.Contains(strings.ToLower(t.Host), q) || strings.Contains(strings.ToLower(t.Method), q)
}

// inRange is the timeline's filter: the request's time, from its start to its end, overlaps the
// selected range.
func (v *netViewer) inRange(t netTransaction) bool {
	if !v.rangeSet {
		return true
	}
	end := t.StartedAt
	if t.FinishedAt != nil {
		end = *t.FinishedAt
	}
	return !end.Before(v.rangeFrom) && !t.StartedAt.After(v.rangeTo)
}

func (v *netViewer) refilter() {
	q := strings.ToLower(v.filter.String())
	v.visible = v.visible[:0]
	for i, t := range v.txns {
		if v.matchesFilter(t, q) && v.inRange(t) {
			v.visible = append(v.visible, i)
		}
	}
}

// removeSelected deletes the selected requests from the list and selects the one after them.
// jacad has no method to forget a request, so they are dropped here only: they stay out of this
// list, and are still in an exported HAR.
func (v *netViewer) removeSelected() {
	first, last, ok := v.selection()
	if !ok {
		return
	}
	for row := first; row <= last; row++ {
		id := v.txns[v.visible[row]].ID
		v.removed[id] = true
		delete(v.bodies, id)
		delete(v.bodyFinal, id)
	}
	kept := v.txns[:0]
	for _, t := range v.txns {
		if !v.removed[t.ID] {
			kept = append(kept, t)
		}
	}
	v.txns = kept
	v.index = make(map[string]int, len(v.txns))
	for n, t := range v.txns {
		v.index[t.ID] = n
	}
	v.selectedID, v.anchorID = "", ""
	v.refilter()
	if len(v.visible) == 0 {
		v.detail = false
		return
	}
	v.selectRow(min(first, len(v.visible)-1))
}

// timeSpan is the capture's time domain: from the first request's start to the last one's end.
func (v *netViewer) timeSpan() (from, to time.Time, ok bool) {
	for i, t := range v.txns {
		end := t.StartedAt
		if t.FinishedAt != nil {
			end = *t.FinishedAt
		}
		if i == 0 || t.StartedAt.Before(from) {
			from = t.StartedAt
		}
		if i == 0 || end.After(to) {
			to = end
		}
	}
	return from, to, len(v.txns) > 0
}

// timelineLanes is how many rows the timeline has.
const timelineLanes = 3

// timeline is the app's timeline strip: every request a bar from its start to its end, colored
// by how it went, in lanes by arrival so neighbours don't hide each other. The selected time
// range is drawn reversed, with a button at the right that clears it.
func (v *netViewer) timeline(cols int) []string {
	from, to, ok := v.timeSpan()
	if !ok || cols < 20 {
		return nil
	}
	span := to.Sub(from)
	if span <= 0 {
		span = time.Millisecond
	}
	column := func(at time.Time) int {
		return max(0, min(cols-1, int(float64(at.Sub(from))/float64(span)*float64(cols-1))))
	}
	styles := make([][]string, timelineLanes)
	for lane := range styles {
		styles[lane] = make([]string, cols)
	}
	for i, t := range v.txns {
		end := t.StartedAt
		if t.FinishedAt != nil {
			end = *t.FinishedAt
		}
		style := statusColor(t)
		if style == sgrDim { // no status yet: still visible on the strip
			style = "\x1b[" + colorCyan + "m"
		}
		for x := column(t.StartedAt); x <= column(end); x++ {
			styles[i%timelineLanes][x] = style
		}
	}
	// The range being dragged, else the one selected, as columns.
	sel0, sel1 := -1, -1
	switch {
	case v.dragging:
		sel0, sel1 = min(v.dragFrom, v.dragTo)-1, max(v.dragFrom, v.dragTo)-1
	case v.rangeSet:
		sel0, sel1 = column(v.rangeFrom), column(v.rangeTo)
	}
	// The app's "Clear time selection" button takes the top right corner while a range is set.
	v.clearX = 0
	if v.rangeSet {
		v.clearX = cols
	}
	out := make([]string, timelineLanes)
	for lane := range out {
		var b strings.Builder
		width := cols
		if lane == 0 && v.rangeSet {
			width = cols - 2
		}
		for x := 0; x < width; x++ {
			style, glyph := styles[lane][x], "━"
			if style == "" {
				style, glyph = sgrDim, "·"
				if lane != timelineLanes/2 {
					glyph = " "
				}
			}
			if x >= sel0 && x <= sel1 {
				style += sgrRev
			}
			b.WriteString(style + glyph + sgrReset)
		}
		if width < cols {
			b.WriteString(" " + sgrBold + "×" + sgrReset)
		}
		out[lane] = b.String()
	}
	return out
}

// timeAt is the time a timeline column (1-based) stands for.
func (v *netViewer) timeAt(x int) time.Time {
	from, to, _ := v.timeSpan()
	if v.timelineCols < 2 {
		return from
	}
	x = max(1, min(x, v.timelineCols))
	return from.Add(time.Duration(float64(to.Sub(from)) * float64(x-1) / float64(v.timelineCols-1)))
}

// timelineMouse handles the timeline's drag: dragging across it selects that time range, which
// filters the list; a plain click clears the selection.
func (v *netViewer) timelineMouse(m mouseEvent, released bool) {
	switch {
	case !v.dragging:
		v.dragging, v.dragFrom, v.dragTo = true, m.x, m.x
	case !released:
		v.dragTo = m.x
	default:
		v.dragging = false
		if v.dragFrom == v.dragTo {
			v.rangeSet = false
		} else {
			// Out to the far edge of the last column dragged over.
			v.rangeSet = true
			v.rangeFrom, v.rangeTo = v.timeAt(min(v.dragFrom, v.dragTo)), v.timeAt(max(v.dragFrom, v.dragTo)+1)
		}
		v.refilter()
	}
}

// selectedRow is the cursor's position among the visible requests, -1 when it isn't there.
func (v *netViewer) selectedRow() int { return v.rowOf(v.selectedID) }

func (v *netViewer) selected() (netTransaction, bool) {
	if i, ok := v.index[v.selectedID]; ok {
		return v.txns[i], true
	}
	return netTransaction{}, false
}

// selectRow selects one visible request and, with the detail pane open, loads its bodies.
func (v *netViewer) selectRow(row int) {
	v.moveTo(row)
	v.anchorID = v.selectedID
}

// extendTo moves the cursor to a visible request, keeping where the selection started, so the
// requests between the two are selected.
func (v *netViewer) extendTo(row int) {
	if v.anchorID == "" {
		v.anchorID = v.selectedID
	}
	v.moveTo(row)
	if v.anchorID == "" {
		v.anchorID = v.selectedID
	}
}

func (v *netViewer) moveTo(row int) {
	if len(v.visible) == 0 {
		return
	}
	t := v.txns[v.visible[clampIndex(row, len(v.visible))]]
	if t.ID != v.selectedID {
		v.selectedID, v.detailTop, v.dsel = t.ID, 0, detailSel{}
	}
	v.scrolled = false
	if v.detail {
		v.fetchBodies(t, false, nil)
	}
}

// rowOf is a request's position among the visible ones, -1 when it isn't there.
func (v *netViewer) rowOf(id string) int {
	i, ok := v.index[id]
	if !ok {
		return -1
	}
	row := sort.SearchInts(v.visible, i)
	if row < len(v.visible) && v.visible[row] == i {
		return row
	}
	return -1
}

// selection is the selected rows among the visible requests, first to last; ok is false when
// nothing is selected. Without a Shift selection it is the cursor's row alone.
func (v *netViewer) selection() (first, last int, ok bool) {
	cursor := v.rowOf(v.selectedID)
	if cursor < 0 {
		return 0, 0, false
	}
	anchor := v.rowOf(v.anchorID)
	if anchor < 0 {
		anchor = cursor
	}
	return min(anchor, cursor), max(anchor, cursor), true
}

// openDetail shows the selected request's detail; focus gives the detail the keys.
func (v *netViewer) openDetail(focus bool) {
	t, ok := v.selected()
	if !ok {
		return
	}
	v.detail, v.detailFocus = true, focus
	v.fetchBodies(t, false, nil)
}

// closeDetail is Esc on the detail: it closes the detail and gives the keys back to the list,
// which keeps the selection.
func (v *netViewer) closeDetail() {
	v.detail, v.detailFocus = false, false
}

func isArrowLeft(k []byte) bool  { return string(k) == "\x1b[D" || string(k) == "\x1bOD" }
func isArrowRight(k []byte) bool { return string(k) == "\x1b[C" || string(k) == "\x1bOC" }

// fetchBodies loads a request's bodies, which list and update events leave out, and runs then
// with them (nil when there are none to have). Bodies fetched while the request was still in
// flight lack the response, so they are fetched again once it has finished; refresh fetches
// again regardless.
func (v *netViewer) fetchBodies(t netTransaction, refresh bool, then func(*netBodies)) {
	if held, ok := v.heldBodies(t); ok && !refresh {
		if then != nil {
			then(held)
		}
		return
	}
	if v.fetching[t.ID] && then == nil {
		return
	}
	v.fetching[t.ID] = true
	finished, clears := t.FinishedAt != nil || t.Error != "", v.clears
	go func() {
		var got *netBodies
		err := v.p.c.Call("network.body", map[string]any{"id": v.id, "transaction": t.ID}, &got)
		v.p.post(func() {
			if clears != v.clears {
				return // the list was cleared meanwhile
			}
			delete(v.fetching, t.ID)
			if err == nil && got != nil {
				v.bodies[t.ID], v.bodyFinal[t.ID] = got, finished
			}
			if then != nil {
				then(v.bodies[t.ID])
			}
		})
	}()
}

// heldBodies is a request's bodies when there is nothing more to fetch for it: it has none, or
// they were fetched after it finished.
func (v *netViewer) heldBodies(t netTransaction) (*netBodies, bool) {
	if !t.BodiesEvicted {
		return v.bodies[t.ID], true
	}
	held, ok := v.bodies[t.ID]
	return held, ok && v.bodyFinal[t.ID]
}

// arming is the capture's arming state: the override engine's for this app, else the agent's
// attach state (NetworkSession.armingState).
func (v *netViewer) arming() armingState {
	if a := v.overrides.arming(v.device.ID, v.state.TargetPackage); a.State != "" && a.State != "idle" {
		return a
	}
	return v.state.AttachState
}

// transport is the interception point of the capture's source: the chosen one, else the first
// one offered.
func (v *netViewer) transport() transport {
	return transportFor(v.device.Platform, v.sourceID())
}

// sourceID is the capture's chosen source, else the first one offered, "" when neither is known.
//
// A mode switch reopens the chooser but keeps SelectedSourceID, which the new mode may not
// offer, so it counts only while HasSelectedMode is set.
func (v *netViewer) sourceID() string {
	if v.state.HasSelectedMode && v.state.SelectedSourceID != "" {
		return v.state.SelectedSourceID
	}
	if len(v.state.OfferedSourceIDs) > 0 {
		return v.state.OfferedSourceIDs[0]
	}
	return ""
}

// chooserSources are the chooser's rows: the offered sources this client can start, agent and
// mitm. A jacad that doesn't send the offered sources only has the agent.
func (v *netViewer) chooserSources() []string {
	if v.state.OfferedSourceIDs == nil {
		return []string{sourceAgent}
	}
	var out []string
	for _, id := range v.state.OfferedSourceIDs {
		if id == sourceAgent || id == sourceMITM {
			out = append(out, id)
		}
	}
	return out
}

// offers is whether the chooser has a row for a source.
func (v *netViewer) offers(sourceID string) bool {
	for _, id := range v.chooserSources() {
		if id == sourceID {
			return true
		}
	}
	return false
}

// choose starts a row of the chooser: the app list for the agent, the device proxy for mitm.
func (v *netViewer) choose(row int) {
	sources := v.chooserSources()
	if len(sources) == 0 {
		return
	}
	v.chooserRow = clampIndex(row, len(sources))
	switch sources[v.chooserRow] {
	case sourceMITM:
		v.selectMITM()
	default:
		v.openApps()
	}
}

// selectMITM captures the whole device through the device proxy. There is no app to choose.
func (v *netViewer) selectMITM() {
	v.err = ""
	v.call("network.select", map[string]any{"id": v.id, "sourceID": sourceMITM})
}

// showsBanner is the app's attach banner: a running capture whose app is closed or came back
// without the agent.
func (v *netViewer) showsBanner() bool {
	state := v.arming().State
	return v.state.IsRunning && (state == "detached" || state == "waitingForApp")
}

// showsChooser is the app's capture chooser: nothing chosen yet and nothing captured.
func (v *netViewer) showsChooser() bool {
	return v.opened && !v.state.HasSelectedMode && !v.state.IsRunning && len(v.txns) == 0
}

// setTarget captures an app with the in-process agent (a running capture restarts on it).
func (v *netViewer) setTarget(pkg string) {
	v.err = ""
	v.call("network.select", map[string]any{"id": v.id, "sourceID": "agent", "package": pkg})
}

// toggle is the app's transport button. There is no resume method: starting again selects the
// same source and app.
func (v *netViewer) toggle() {
	switch {
	case v.state.IsRunning:
		v.call("network.stop", map[string]any{"id": v.id})
	case v.device.isMac():
		v.err = ""
		v.call("network.select", map[string]any{"id": v.id, "sourceID": sourceBrowser})
	case v.state.SelectedSourceID == sourceMITM && v.offers(sourceMITM):
		v.selectMITM()
	case v.state.TargetPackage != "" && v.offers(sourceAgent):
		v.setTarget(v.state.TargetPackage)
	case v.offers(sourceAgent):
		v.openApps()
	case v.offers(sourceMITM):
		v.selectMITM()
	}
}

// clear forgets the captured requests here and in jacad. Updates published before the clear
// lands would bring rows back, so they are dropped until the list has been read again after it.
func (v *netViewer) clear() {
	v.reset()
	v.clearing = true
	clears := v.clears
	go func() {
		err := v.p.c.Call("network.clear", map[string]any{"id": v.id}, nil)
		var txns []netTransaction
		if err == nil {
			err = v.p.c.CallTimeout("network.transactions", map[string]any{"id": v.id}, &txns, time.Minute)
		}
		v.p.post(func() {
			if clears != v.clears {
				return // cleared again meanwhile; that clear finishes the job
			}
			v.clearing = false
			if err != nil {
				v.err = err.Error()
				return
			}
			v.reset()
			v.clears = clears // reset counts a clear; this one is the same
			v.upsert(txns)
		})
	}()
}

// reset empties the list and everything held about its requests.
func (v *netViewer) reset() {
	v.txns, v.visible, v.index = nil, nil, map[string]int{}
	v.bodies, v.bodyFinal, v.fetching = map[string]*netBodies{}, map[string]bool{}, map[string]bool{}
	v.selectedID, v.anchorID, v.detail, v.top, v.scrolled = "", "", false, 0, false
	v.removed, v.rangeSet, v.dragging = map[string]bool{}, false, false
	v.clears++
}

// exportHAR is the app's Export HAR: every captured request, saved where the macOS save dialog
// says, under the app's default name for a network tab.
func (v *netViewer) exportHAR() {
	name := strings.NewReplacer("/", "-", ":", "-").Replace("Network · "+v.device.displayModel()) + ".har"
	v.err, v.saved = "", ""
	go func() {
		var encoded *string
		err := v.p.c.CallTimeout("network.exportHAR", map[string]any{"id": v.id}, &encoded, 2*time.Minute)
		path := ""
		if err == nil && encoded != nil {
			var data []byte
			if data, err = base64.StdEncoding.DecodeString(*encoded); err == nil {
				if path, err = chooseSavePath(name); err == nil && path != "" {
					err = os.WriteFile(path, data, 0o644)
				}
			}
		}
		v.p.post(func() {
			if err != nil {
				v.err = err.Error()
				return
			}
			v.saved = path
		})
	}()
}

func (v *netViewer) copy(text string) {
	write := copyToClipboard
	go func() {
		err := write(text)
		v.p.post(func() {
			if err != nil {
				v.err = err.Error()
			} else {
				v.snack.show(v.p, copiedNotice)
			}
		})
	}()
}

// overrideBadge is the request's override mark and why (NetworkSessionView.overrideBadge):
// applied by a rule, about to be, or matched by a rule that can't run here.
type overrideBadge struct {
	kind string // "", "applied", "willApply" or "blocked"
	text string // the rule's name, or why it is blocked
}

func (v *netViewer) badge(t netTransaction) overrideBadge {
	if t.OverriddenByRuleID != "" {
		for _, r := range v.overrides.Rules {
			if strings.EqualFold(r.ID, t.OverriddenByRuleID) {
				return overrideBadge{"applied", r.displayName()}
			}
		}
	}
	if !v.overrides.MasterEnabled {
		return overrideBadge{}
	}
	rule, ok := v.matchingRule(t)
	if !ok {
		return overrideBadge{}
	}
	if msg := v.arming().blockedMessage(); msg != "" {
		return overrideBadge{"blocked", msg}
	}
	if v.state.HasRunningSource {
		if msg := skipReason(rule, v.transport(), v.state.InterceptCapabilities, v.overrides.MasterEnabled); msg != "" {
			return overrideBadge{"blocked", msg}
		}
	}
	return overrideBadge{"willApply", rule.displayName()}
}

// matchingRule is the rule that would answer t on this capture's transport.
func (v *netViewer) matchingRule(t netTransaction) (overrideRule, bool) {
	return v.rules.matchingRuleOn(t.URL, t.Method, v.transport(), v.device.ID)
}

// gateReason is why this request can't be overridden, "" when it can.
func (v *netViewer) gateReason(t netTransaction) string {
	return rowGateReason(v.transport(), t, v.state.HasRunningSource, v.arming())
}

// overrideRequest opens the editor for a request: on the rule that already answers it, unless
// another is asked for, else on a new rule seeded with the response it got.
func (v *netViewer) overrideRequest(t netTransaction, another bool) {
	if reason := v.gateReason(t); reason != "" {
		v.err = reason
		return
	}
	if existing, ok := v.matchingRule(t); ok && !another {
		v.openEditor(existing, false, "")
		return
	}
	v.fetchBodies(t, false, func(b *netBodies) {
		var body []byte
		if b != nil {
			body = b.Response
		}
		rule, err := seedRule(t, body)
		if err != nil {
			v.err = err.Error()
			return
		}
		v.openEditor(rule, true, seedWarning(t, body))
	})
}

// openRowMenu shows the app's request menu (NetworkSessionView.rowMenu) at a cell.
func (v *netViewer) openRowMenu(t netTransaction, x, y int) {
	first := "Override response…"
	existing, matched := v.matchingRule(t)
	if matched {
		first = "Edit override “" + existing.displayName() + "”"
	}
	items := []menuItem{{first, func() { v.overrideRequest(t, false) }}}
	if matched {
		items = append(items, menuItem{"Add another override…", func() { v.overrideRequest(t, true) }})
	}
	items = append(items,
		menuItem{},
		menuItem{"Copy as cURL", func() { v.copyCurl(t) }},
		menuItem{"Copy URL", func() { v.copy(t.URL) }},
		menuItem{"Copy response body", func() {
			v.fetchBodies(t, false, func(b *netBodies) {
				if b != nil {
					v.copy(string(b.Response))
				}
			})
		}},
		menuItem{},
		menuItem{"Filter by this host", func() {
			v.filter.set(t.Host)
			v.refilter()
		}})
	v.menu, v.focus = &popupMenu{x: x, y: y, items: items}, netMenu
}

// openBrowser opens This Mac's Chrome window again after it was closed.
func (v *netViewer) openBrowser() {
	if v.device.isMac() && v.state.IsRunning {
		v.call("network.openBrowser", map[string]any{"id": v.id})
	}
}

func (v *netViewer) openApps() {
	if v.device.isMac() || !v.offers(sourceAgent) {
		return // no apps: the capture is the Chrome window, or the whole device
	}
	v.focus = netApps
	v.apps.open(v.p, v.device.ID)
}

// handleKey: see helpKeys for the list. In the filter field, Enter or Esc leaves it.
func (v *netViewer) handleKey(k []byte) bool {
	// Ctrl-C quits, except in the editor, where it copies and quitting would drop the draft.
	if len(k) == 1 && k[0] == 0x03 && v.focus != netEditor {
		return true
	}
	if m, ok := parseMouse(k); ok {
		v.mouse(m)
		return false
	}
	v.saved = ""
	switch v.focus {
	case netOverrides, netEditor:
		v.overridesKey(k)
		return false
	case netMenu:
		v.menuKey(k)
		return false
	case netHelp:
		if isEsc(k) || isEnter(k) || (len(k) == 1 && (k[0] == 'q' || k[0] == '?')) {
			v.focus = netList
		}
		return false
	case netSearch:
		if isEnter(k) || isEsc(k) {
			v.focus = netList
		} else if v.filter.handle(k) {
			v.refilter()
		}
		return false
	case netApps:
		switch pkg, done := v.apps.key(k); {
		case pkg != "":
			v.focus = netList
			v.setTarget(pkg)
		case done:
			v.focus = netList
		}
		return false
	}
	row := v.selectedRow()
	if v.detail && v.detailFocus && v.detailKey(k) {
		return false
	}
	switch {
	case string(k) == "\x1b[1;2A": // Shift+Up, Down, PgUp and PgDn extend the selection
		v.extendTo(max(0, row-1))
	case string(k) == "\x1b[1;2B":
		v.extendTo(row + 1)
	case string(k) == "\x1b[5;2~":
		v.extendTo(max(0, row-max(1, v.listRows)))
	case isShiftPageDown(k):
		v.extendTo(row + max(1, v.listRows))
	case isPageUp(k):
		v.page(-1)
	case isPageDown(k):
		v.page(1)
	case isArrowRight(k) && v.detail:
		v.detailFocus = true
	case isUp(k) && v.showsChooser():
		v.chooserRow = max(0, v.chooserRow-1)
	case isDown(k) && v.showsChooser():
		v.chooserRow = clampIndex(v.chooserRow+1, len(v.chooserSources()))
	case isUp(k):
		v.selectRow(max(0, row-1))
	case isDown(k):
		v.selectRow(row + 1)
	case isEnter(k):
		switch {
		case v.showsChooser():
			v.choose(v.chooserRow)
		case row < 0:
			v.selectRow(len(v.visible) - 1)
			v.openDetail(true)
		default:
			v.openDetail(true)
		}
	case isEsc(k):
		switch {
		case v.detail:
			v.closeDetail()
		case v.rangeSet:
			v.rangeSet = false
			v.refilter()
		case v.back != nil:
			v.leave(false)
			v.back()
		}
	case len(k) == 3 && k[0] == 0x1b && k[1] == '[' && k[2] == 'Z': // Shift-Tab
		v.setTab(v.tab - 1)
	case len(k) != 1:
	case k[0] == '\t':
		v.setTab(v.tab + 1)
	case k[0] >= '1' && k[0] <= '5' && v.detail:
		v.setTab(int(k[0] - '1'))
	case k[0] == 'q':
		return true
	case k[0] == 'G':
		v.selectedID, v.anchorID, v.scrolled = "", "", false // back to following new requests
	case k[0] == ' ' || k[0] == 'p':
		v.toggle()
	case k[0] == 'c':
		v.clear()
	case k[0] == 'a':
		v.openApps()
	case k[0] == 'b':
		v.openBrowser()
	case k[0] == '/':
		v.focus = netSearch
	case k[0] == 'S' || k[0] == 'e':
		v.exportHAR()
	case k[0] == 'o':
		v.openOverridesList()
	case k[0] == 'P':
		v.toggleMaster()
	case k[0] == 'O':
		if t, ok := v.selected(); ok {
			v.overrideRequest(t, false)
		}
	case k[0] == 'm':
		if t, ok := v.selected(); ok && row >= 0 {
			v.openRowMenu(t, 8, v.listTop+row-v.top)
		}
	case k[0] == 'C' || k[0] == 'y':
		v.copyBody()
	case k[0] == 'u':
		if t, ok := v.selected(); ok {
			v.copyCurl(t)
		}
	case k[0] == 0x7f || k[0] == 0x08: // Backspace
		v.removeSelected()
	case k[0] == 'R':
		v.relaunch()
	case k[0] == 'M':
		v.openModeMenu()
	case k[0] == 'I':
		v.installCA()
	case k[0] == 'x' && v.showsSetupBanner():
		v.dismissSetup()
	case k[0] == 'B' && v.setup.offerReboot:
		v.rebootSimulator()
	case k[0] == '?':
		v.focus = netHelp
	}
	return false
}

// detailLine is one line of the detail content: the value it shows part of (empty for a
// heading or a button), where the value starts on the line, whether a long value wrapped onto
// it, and for a button what a click on its cells x0..x1 does. Lines with the same group (other
// than 0) show one value that has line breaks of its own: a double click selects them all.
type detailLine struct {
	value  string
	valueX int
	cont   bool
	group  int
	act    func()
	x0, x1 int
}

// detailSel is the text selected in the detail content, from the cell the drag began on to the
// one it is on: line indexes into the content and cells of a line.
type detailSel struct {
	on, dragging bool
	line0, col0  int
	line1, col1  int
}

// ordered is the selection's ends, the earlier first.
func (s detailSel) ordered() (l0, c0, l1, c1 int) {
	if s.line0 < s.line1 || (s.line0 == s.line1 && s.col0 <= s.col1) {
		return s.line0, s.col0, s.line1, s.col1
	}
	return s.line1, s.col1, s.line0, s.col0
}

// span is the cells of line i the selection covers. The padding before the part of a value
// that wrapped onto the line is never part of it.
func (s detailSel) span(i int, meta []detailLine) (from, to int, ok bool) {
	if !s.on || i < 0 || i >= len(meta) {
		return 0, 0, false
	}
	l0, c0, l1, c1 := s.ordered()
	if i < l0 || i > l1 {
		return 0, 0, false
	}
	from, to = 0, 1<<30
	if i == l0 {
		from = c0
	}
	if i == l1 {
		to = c1 + 1
	}
	if meta[i].cont {
		from = max(from, meta[i].valueX)
	}
	return from, to, from < to
}

// cellSlice is the part of s in cells from..to (to excluded).
func cellSlice(s string, from, to int) string {
	var b strings.Builder
	at, prev := 0, 0
	for _, r := range s {
		w := widthAfter(r, prev)
		if at >= from && at+w <= to {
			b.WriteRune(r)
		}
		at += w
		prev = runeWidth(r)
	}
	return b.String()
}

// detailContent is the content of a detail pane as last drawn and the text selected in it with
// the mouse. The network and database viewers both hold one.
type detailContent struct {
	detailTop   int          // the first content line drawn
	detailMeta  []detailLine // the content's lines: their values and buttons,
	detailDrawn []string     // and the lines as drawn
	detailText  []string     // their text without styles, where a viewer keeps it
	detailFirst int          // the screen row of the first content line
	detailX     int          // the screen column of a content line's first cell
	detailRoom  int          // the content rows on screen
	dsel        detailSel    // the text selected in the content
	lastPress   time.Time    // the last press on the content, and its line,
	lastLine    int          // for a double click
}

// selectedDetailText is the selection as text: a value that wrapped over several lines comes
// back in one piece, and other lines are separated by a line break.
func (d *detailContent) selectedDetailText() string {
	if !d.dsel.on {
		return ""
	}
	l0, _, l1, _ := d.dsel.ordered()
	var b strings.Builder
	for i := max(0, l0); i <= l1 && i < len(d.detailDrawn) && i < len(d.detailMeta); i++ {
		from, to, ok := d.dsel.span(i, d.detailMeta)
		if !ok {
			continue
		}
		if b.Len() > 0 && !d.detailMeta[i].cont {
			b.WriteString("\n")
		}
		part := cellSlice(stripSGR(d.detailDrawn[i]), from, to)
		if i == l1 || i+1 >= len(d.detailMeta) || !d.detailMeta[i+1].cont {
			part = strings.TrimRight(part, " ")
		}
		b.WriteString(part)
	}
	return b.String()
}

// detailAt is the content line and cell under the pointer, kept inside the content.
func (d *detailContent) detailAt(m mouseEvent) (line, col int) {
	line = max(0, min(m.y-d.detailFirst+d.detailTop, len(d.detailMeta)-1))
	return line, max(0, m.x-d.detailX)
}

// detailPress is a left press on the detail content: a button is pressed, a second press on
// the same line selects and copies its whole value, and anything else starts a selection that
// a drag extends. copy is what copies a text.
func (d *detailContent) detailPress(m mouseEvent, copy func(string)) {
	if m.y < d.detailFirst || len(d.detailMeta) == 0 || m.y-d.detailFirst+d.detailTop >= len(d.detailMeta) {
		d.dsel = detailSel{}
		return
	}
	line, col := d.detailAt(m)
	if l := d.detailMeta[line]; l.act != nil {
		if col >= l.x0 && col <= l.x1 {
			l.act()
		}
		d.dsel = detailSel{}
		return
	}
	now := time.Now()
	double := line == d.lastLine && now.Sub(d.lastPress) < 400*time.Millisecond
	d.lastPress, d.lastLine = now, line
	if double && d.detailMeta[line].value != "" {
		first, last := line, line
		for first > 0 && d.detailMeta[first].cont {
			first--
		}
		for last+1 < len(d.detailMeta) && d.detailMeta[last+1].cont {
			last++
		}
		// A value with line breaks of its own: all of its lines.
		if group := d.detailMeta[line].group; group != 0 {
			for first > 0 && d.detailMeta[first-1].group == group {
				first--
			}
			for last+1 < len(d.detailMeta) && d.detailMeta[last+1].group == group {
				last++
			}
		}
		d.dsel = detailSel{on: true, line0: first, col0: d.detailMeta[first].valueX, line1: last, col1: 1 << 29}
		copy(d.detailMeta[line].value)
		return
	}
	d.dsel = detailSel{on: true, dragging: true, line0: line, col0: col, line1: line, col1: col}
}

// detailDrag extends the selection to the pointer, scrolling when it leaves the content, and
// on release copies what is selected. A press released where it began selects nothing.
func (d *detailContent) detailDrag(m mouseEvent, released bool, copy func(string)) {
	if !released {
		switch {
		case m.y < d.detailFirst:
			d.detailTop = max(0, d.detailTop-1)
		case m.y >= d.detailFirst+d.detailRoom:
			d.detailTop++
		}
		d.dsel.line1, d.dsel.col1 = d.detailAt(m)
		return
	}
	d.dsel.dragging = false
	if d.dsel.line0 == d.dsel.line1 && d.dsel.col0 == d.dsel.col1 {
		d.dsel = detailSel{}
		return
	}
	d.lastPress = time.Time{} // a drag is not the first half of a double click
	if text := d.selectedDetailText(); text != "" {
		copy(text)
	}
}

// detailMenu is a right click on the detail content: Copy for the value under the pointer, or
// for the selection when the click is on it. Nil when there is nothing to copy there.
func (d *detailContent) detailMenu(m mouseEvent, copy func(string)) *popupMenu {
	if m.y < d.detailFirst || len(d.detailMeta) == 0 || m.y-d.detailFirst+d.detailTop >= len(d.detailMeta) {
		return nil
	}
	line, _ := d.detailAt(m)
	text := d.detailMeta[line].value
	if _, _, ok := d.dsel.span(line, d.detailMeta); ok {
		text = d.selectedDetailText()
	}
	if text == "" {
		return nil
	}
	return &popupMenu{x: m.x, y: m.y, items: []menuItem{{"Copy", func() { copy(text) }}}}
}

// detailRows draws the content lines w cells wide in at most room rows, from detailTop, with
// the selected text reversed, and records them for the mouse. Each row is a space and the
// line, filled out to w cells. Only the lines on screen are looked at, so the content can be
// long.
func (d *detailContent) detailRows(lines []string, meta []detailLine, w, room int) []string {
	d.detailMeta, d.detailDrawn, d.detailText, d.detailRoom = meta, lines, nil, room
	d.detailTop = max(0, min(d.detailTop, len(lines)-room))
	var out []string
	for i := d.detailTop; i < len(lines) && len(out) < room; i++ {
		row := lines[i]
		if cellWidth(stripSGR(row)) > w-1 { // a line the pane is too narrow for, plain and cut
			row = clip(stripSGR(row), w-1)
		}
		if from, to, ok := d.dsel.span(i, meta); ok { // the selected part, reversed
			text := stripSGR(row)
			row = cellSlice(text, 0, from) + sgrRev + cellSlice(text, from, to) + sgrReset + cellSlice(text, to, cellWidth(text))
		}
		out = append(out, " "+padStyled(row, w-1))
	}
	return out
}

// page scrolls the detail pane when it is open, else moves the selection a page.
// page moves the selection a page.
func (v *netViewer) page(dir int) {
	v.selectRow(max(0, v.selectedRow()+dir*max(1, v.listRows)))
}

// detailKey handles a key while the detail has the keys: the arrows and j, k scroll it, Page Up
// and Down page it, and Left and Right switch its tabs. It reports whether the key was one of
// those; the others act as they do on the list.
func (v *netViewer) detailKey(k []byte) bool {
	switch {
	case isPageUp(k):
		v.detailTop = max(0, v.detailTop-max(1, v.listRows-4))
	case isPageDown(k):
		v.detailTop += max(1, v.listRows-4)
	case isUp(k):
		v.detailTop = max(0, v.detailTop-1)
	case isDown(k):
		v.detailTop++
	case isArrowLeft(k):
		v.setTab(v.tab - 1)
	case isArrowRight(k):
		v.setTab(v.tab + 1)
	case isEnter(k):
	default:
		return false
	}
	return true
}

func (v *netViewer) setTab(tab int) {
	if v.detail {
		v.tab, v.detailTop, v.dsel = (tab+len(netTabs))%len(netTabs), 0, detailSel{}
	}
}

// copyBody copies the selected request's response body, fetching it if need be, as the menu's
// "Copy response body" does. With the Request tab open it copies the request body shown there,
// as that tab's Copy button does.
func (v *netViewer) copyBody() {
	t, ok := v.selected()
	if !ok {
		return
	}
	request := v.detail && v.tab == tabRequest
	v.fetchBodies(t, false, func(*netBodies) { v.copy(v.bodyText(t, request)) })
}

// copyCurl copies the request as a curl command, with its body fetched first when it isn't held.
func (v *netViewer) copyCurl(t netTransaction) {
	v.fetchBodies(t, false, func(b *netBodies) {
		var body []byte
		if b != nil {
			body = b.Request
		}
		v.copy(curlCommand(t, body))
	})
}

func (v *netViewer) menuKey(k []byte) {
	switch {
	case isEsc(k) || (len(k) == 1 && k[0] == 'q'):
		v.menu, v.focus = nil, netList
	case isUp(k):
		v.menu.move(-1)
	case isDown(k):
		v.menu.move(1)
	case isEnter(k):
		menu := v.menu
		v.menu, v.focus = nil, netList
		menu.items[menu.selected].act()
	}
}

func (v *netViewer) mouse(m mouseEvent) {
	const wheelUp, wheelDown, wheelLines = 64, 65, 3
	// A drag on the timeline runs until the button is released (the report's final byte in SGR
	// mode; some terminals send button 3 instead).
	released := !m.press || (m.button&mouseDrag == 0 && m.button&3 == 3)
	if v.dragging && (m.button&mouseDrag != 0 || released) {
		v.timelineMouse(m, released)
		return
	}
	if v.dsel.dragging && (m.button&mouseDrag != 0 || released) {
		v.detailDrag(m, released, v.copy)
		return
	}
	if !m.press {
		return
	}
	switch v.focus {
	case netOverrides, netEditor:
		v.overridesMouse(m)
		return
	case netHelp:
		if m.button == 0 {
			v.focus = netList
		}
		return
	case netMenu:
		menu := v.menu
		v.menu, v.focus = nil, netList
		if i := menu.itemAt(m.x, m.y); m.button == 0 && i >= 0 {
			menu.items[i].act()
		}
		return
	case netApps:
		switch pkg, done := v.apps.mouse(m); {
		case pkg != "":
			v.focus = netList
			v.setTarget(pkg)
		case done:
			v.focus = netList
		}
		return
	}
	rows, _ := termSize()
	inDetail := v.detail && m.x > v.listW
	row := m.y - v.listTop + v.top
	switch {
	case m.button == wheelUp || m.button == wheelDown:
		by := wheelLines
		if m.button == wheelUp {
			by = -wheelLines
		}
		if inDetail {
			v.detailTop = max(0, v.detailTop+by)
		} else {
			v.top, v.scrolled = max(0, v.top+by), true
		}
	case m.button != 0 && m.button != 2:
	case m.y <= toolbarRows(rows):
		v.focus = netList
		for i := len(v.hits) - 1; m.button == 0 && i >= 0; i-- {
			if h := v.hits[i]; m.x >= h.x0 && m.x <= h.x1 {
				h.act()
				return
			}
		}
	case m.button == 0 && v.timelineTop > 0 && m.y >= v.timelineTop && m.y < v.timelineTop+timelineLanes:
		v.focus = netList
		if v.clearX > 0 && m.y == v.timelineTop && m.x >= v.clearX-1 {
			v.rangeSet = false
			v.refilter()
			return
		}
		v.timelineMouse(m, false)
	case m.button == 0 && v.bannerHit(m):
	case m.button == 0 && m.y == rows && v.helpX0 > 0 && m.x >= v.helpX0 && m.x <= v.helpX1:
		v.focus = netHelp
	case inDetail && m.button == 0:
		v.focus = netList
		if m.y == v.listTop-1 && m.x >= v.closeX0 && m.x <= v.closeX1 {
			v.closeDetail()
			return
		}
		v.detailFocus = true
		switch {
		case m.y == v.listTop:
			for _, h := range v.tabHits {
				if m.x >= h.x0 && m.x <= h.x1 {
					h.act()
				}
			}
		default:
			v.detailPress(m, v.copy)
		}
	case inDetail && m.button == 2:
		if menu := v.detailMenu(m, v.copy); menu != nil {
			v.menu, v.focus = menu, netMenu
		}
	case inDetail:
	case v.showsChooser() && m.button == 0 && m.y >= v.listTop:
		v.focus = netList
		for i, h := range v.chooserHits {
			if m.y >= h.x0 && m.y <= h.x1 {
				v.choose(i)
			}
		}
	case m.y >= v.listTop && row >= 0 && row < len(v.visible) && m.y < v.listTop+v.listRows:
		v.focus = netList
		v.selectRow(row)
		if m.button == 2 {
			if t, ok := v.selected(); ok {
				v.openRowMenu(t, m.x, m.y)
			}
			return
		}
		v.openDetail(false)
	}
}

func (v *netViewer) helpKeys() [][2]string {
	keys := [][2]string{
		{"p  space", "Start capture"},
		{"c", "Clear"},
		{"a", "Inspect app"},
		{"/", "Filter by URL, host, method…"},
		{"o", "Overrides"},
		{"O", "Override response…"},
		{"P", "Pause all overrides"},
		{"S", "Export HAR"},
		{"j  k", "Select request"},
		{"Enter  →", "Inspect request"},
		{"Esc", "Back"},
		{"Tab  ←  →  1-5", "Switch tab"},
		{"PgUp  PgDn", "Scroll"},
		{"C", "Copy response body"},
		{"u", "Copy as cURL"},
		{"Shift+↑ ↓ PgUp PgDn", "Select requests"},
		{"Backspace", "Delete request"},
		{"m", "Request menu"},
		{"G", "Follow new requests"},
		{"M", "inspection mode"},
	}
	if v.state.IsRunning {
		keys[0][1] = "Stop capture"
	}
	switch {
	case v.device.isMac():
		keys[2] = [2]string{"b", "Open Chrome"}
	case !v.offers(sourceAgent):
		keys = append(keys[:2], keys[3:]...) // the device proxy has no app to choose
	}
	// R acts only on a detached agent; a simulator on the MITM proxy never detaches.
	if v.device.Platform == "iosSimulator" && v.offers(sourceAgent) {
		keys = append(keys, [2]string{"R", "Relaunch & re-attach"})
	}
	return append(keys, [2]string{"?", "Help"}, [2]string{"q", "Quit"})
}

func (v *netViewer) draw() {
	rows, cols := termSize()
	if v.focus == netApps {
		paintRows(v.apps.frame(rows, cols))
		return
	}
	var frame []string
	line := func(s string) { frame = append(frame, s) }

	for _, row := range v.toolbar(cols, toolbarRows(rows)) {
		line(row)
	}
	// Under the toolbar: a failed call, the capture's status line (the agent's progress and
	// errors), or where the last export went.
	switch {
	case v.err != "":
		line(sgrRed + fit(sanitize(v.err), cols) + sgrReset)
	case v.state.StatusMessage != "":
		line(sgrDim + fit(sanitize(v.state.StatusMessage), cols) + sgrReset)
	case v.saved != "":
		line(sgrGreen + fit("↓ "+sanitize(v.saved), cols) + sgrReset)
	}
	v.bannerHits = v.bannerHits[:0]
	if v.showsBanner() {
		for _, row := range v.banner(cols, rows >= 24, len(frame)+1) {
			line(row)
		}
	}
	if v.showsSetupBanner() {
		for _, row := range v.setupBanner(cols) {
			line(row)
		}
	}

	// The timeline, in a pane tall enough to spare it the rows.
	v.timelineTop, v.timelineCols = 0, cols
	if rows >= 24 {
		if strip := v.timeline(cols); strip != nil {
			v.timelineTop = len(frame) + 1
			frame = append(frame, strip...)
		}
	}

	// The list, with the detail pane beside it when open.
	v.listW = cols
	if v.detail {
		v.listW = max(40, cols*9/20)
		if cols-v.listW < 30 { // too narrow to split: the detail takes the pane
			v.listW = 0
		}
	}
	v.listTop = len(frame) + 2
	v.listRows = max(1, rows-len(frame)-2)
	list := v.listColumn(v.listW, v.listRows+1)
	if !v.detail {
		frame = append(frame, list...)
	} else {
		detail := v.detailColumn(cols-v.listW-1, v.listRows+1)
		for i := range detail {
			left := ""
			if v.listW > 0 {
				left = list[i] + borderStyle + "│" + sgrReset
			}
			line(left + detail[i])
		}
	}
	line(v.statusBar(cols))

	switch {
	case v.focus == netHelp:
		if box := keysBox(v.helpKeys(), rows, cols); len(box) > 0 {
			frame = overlay(frame, box, max(0, (rows-len(box))/2), max(0, (cols-cellWidth(stripSGR(box[0])))/2))
		}
	case v.focus == netMenu && v.menu != nil:
		box := v.menu.box(rows, cols)
		frame = overlay(frame, box, v.menu.top-1, v.menu.left-1)
	case v.focus == netOverrides || v.focus == netEditor:
		box, top, left := v.overridesBox(rows, cols)
		frame = overlay(frame, box, top, left)
	}
	paintRows(v.snack.over(frame, rows, cols))
}

// barBuilder lays a toolbar out left to right, one or three rows tall, recording what each
// span does when clicked.
type barBuilder struct {
	top, mid, bottom strings.Builder
	used, cols       int
	tall             bool
	hits             []hit
}

func (b *barBuilder) pad() int {
	if b.tall {
		return 3
	}
	return 2
}

// chipWidth is the width a chip with this label takes.
func (b *barBuilder) chipWidth(label string) int { return cellWidth(label) + 2*b.pad() }

func (b *barBuilder) add(w int, top, mid, bottom string, act func()) {
	gap := strings.Repeat(" ", min(b.used, 1))
	b.top.WriteString(gap + top)
	b.mid.WriteString(gap + mid)
	b.bottom.WriteString(gap + bottom)
	b.used += len(gap) + w
	if act != nil {
		b.hits = append(b.hits, hit{x0: b.used - w + 1, x1: b.used, act: act})
	}
}

// chip adds a clickable label, a block of style when it has one. It is left out when it doesn't fit.
func (b *barBuilder) chip(label, style string, act func()) {
	w := b.chipWidth(label)
	if b.used+min(b.used, 1)+w > b.cols {
		return
	}
	pad := strings.Repeat(" ", b.pad())
	blank := style + strings.Repeat(" ", w) + sgrReset
	b.add(w, blank, style+pad+label+pad+sgrReset, blank, act)
}

// field adds a text field w cells wide.
func (b *barBuilder) field(t *textInput, placeholder string, focused bool, w int, act func()) {
	if !b.tall {
		b.add(w, "", renderField(t, placeholder, focused, w, sgrUnder), "", act)
		return
	}
	box := boxedField(t, placeholder, focused, w, "")
	b.add(w, box[0], box[1], box[2], act)
}

func (b *barBuilder) rows() []string {
	if !b.tall {
		return []string{b.mid.String()}
	}
	return []string{b.top.String(), b.mid.String(), b.bottom.String()}
}

// overridesBadge is the count on the Overrides button and its tint, by how the rules stand on
// this capture (OverridesToolbarButton.phase).
func (v *netViewer) overridesBadge() (text, style string) {
	enabled := 0
	for _, r := range v.overrides.Rules {
		if v.overrides.ruleOn(r) {
			enabled++
		}
	}
	arming := v.arming()
	switch {
	case enabled == 0:
		return "", ""
	case !v.overrides.MasterEnabled, !v.state.HasRunningSource:
		return fmt.Sprint(enabled), sgrDim
	case !v.state.InterceptWired:
		return fmt.Sprint(enabled), sgrYellow
	case arming.State == "failed" || arming.State == "agentTooOld":
		return "!", sgrRed
	case arming.blockedMessage() != "":
		return fmt.Sprintf("0 of %d", enabled), sgrYellow
	}
	ok := 0
	for _, r := range v.overrides.Rules {
		if v.overrides.ruleOn(r) && skipReason(r, v.transport(), v.state.InterceptCapabilities, true) == "" {
			ok++
		}
	}
	if ok < enabled {
		return fmt.Sprintf("%d of %d", ok, enabled), sgrYellow
	}
	return fmt.Sprint(enabled), borderStyle
}

// toolbar is the app's: start/stop, Clear, the app being inspected, the filter, Overrides and
// Export HAR, with the capture mode at the right where there is room.
func (v *netViewer) toolbar(cols, height int) []string {
	b := &barBuilder{cols: cols, tall: height >= 3}
	if v.state.IsRunning {
		b.chip("■", badgeStyle(colorRed), v.toggle)
	} else {
		b.chip("▶", badgeStyle(colorGreen), v.toggle)
	}
	b.chip("Clear", "", v.clear)
	mode := "in-process"
	switch {
	case v.device.isMac():
		mode = "browser"
		if v.state.IsRunning {
			b.chip("Open Chrome", sgrBold, v.openBrowser)
		}
	case v.sourceID() == sourceMITM:
		mode = "proxy" // the whole device: there is no app to choose
	default:
		app := "Inspect app"
		if pkg := v.state.TargetPackage; pkg != "" {
			app = pkg[strings.LastIndex(pkg, ".")+1:]
		}
		b.chip(app+" ▼", sgrBold, v.openApps)
	}

	overrides := "Overrides"
	badge, tint := v.overridesBadge()
	if badge != "" {
		overrides += " " + badge
	}
	const export = "Export HAR"
	trailing := b.chipWidth(overrides) + 1 + b.chipWidth(export) + 1
	if w := min(64, cols-b.used-1-trailing); w >= 16 {
		b.field(&v.filter, "Filter by URL, host, method…", v.focus == netSearch, w, func() { v.focus = netSearch })
	}
	b.chip(overrides, tint, v.openOverridesList)
	b.chip(export, "", v.exportHAR)
	if room := cols - b.used - 2 - len(mode); room >= 0 { // the mode, flush right
		lead := strings.Repeat(" ", room+1)
		b.add(room+1+len(mode), lead, lead[:room+1]+sgrDim+mode+sgrReset, lead, nil)
	}
	v.hits = b.hits
	return b.rows()
}

// autoReattachKey is the app's setting for relaunching a simulator app without asking
// (FeatureFlags.simulatorAutoReattachKey).
const autoReattachKey = "simulatorAutoReattachEnabled"

// writeBoolDefault stores one of the app's settings as a boolean. Replaced in tests.
var writeBoolDefault = func(key string, value bool) error {
	out, err := exec.Command("defaults", "write", jacaDefaultsDomain, key, "-bool", fmt.Sprint(value)).CombinedOutput()
	if err != nil {
		if text := firstLine(out); text != "" {
			return errors.New(text)
		}
	}
	return err
}

// relaunch is the banner's action: relaunch the app with the agent injected.
func (v *netViewer) relaunch() {
	if v.arming().State == "detached" {
		v.call("network.relaunchToAttach", map[string]any{"id": v.id})
	}
}

// offersAutoReattach is whether the banner shows the app's setting for relaunching without
// asking: it exists for the iOS Simulator, and only in Agent HTTPS debugging.
func (v *netViewer) offersAutoReattach() bool {
	return v.device.Platform == "iosSimulator" && v.mode == modeAgent && v.arming().State == "detached"
}

// toggleAutoReattach flips the app's setting. It shows the new value at once and goes back if
// the write fails.
func (v *netViewer) toggleAutoReattach() {
	on := !v.autoReattach
	v.autoReattach, v.err = on, ""
	go func() {
		if err := writeBoolDefault(autoReattachKey, on); err != nil {
			v.p.post(func() { v.autoReattach, v.err = !on, err.Error() })
		}
	}()
}

// bannerHit runs the banner button under a click, if there is one.
func (v *netViewer) bannerHit(m mouseEvent) bool {
	for _, h := range v.bannerHits {
		if m.y == h.row && m.x >= h.x0 && m.x <= h.x1 {
			h.act(0)
			return true
		}
	}
	return false
}

// bannerNotice is the banner's text in w cells: the title in bold yellow, then why.
func bannerNotice(title, message string, w int) string {
	text := clip(title+"  "+message, max(0, w-2))
	head, rest := text, ""
	if len(text) > len(title) {
		head, rest = text[:len(title)], text[len(title):]
	}
	return padStyled(sgrYellow+"▌"+sgrReset+" "+sgrYellow+sgrBold+head+sgrReset+rest, w)
}

// banner is the app's attach banner (a warning notice): why capture paused, and for an app that
// came back without the agent, the button that brings it back. Tall, it takes two rows, the
// second holding the button and, on the iOS Simulator, the app's setting to do it without
// asking. top is the screen row it starts on.
func (v *netViewer) banner(cols int, tall bool, top int) []string {
	const action, auto = " R  Relaunch & re-attach ", "Re-attach to iOS Simulator apps automatically"
	arming := v.arming()
	title := "Capture detached"
	if arming.State == "waitingForApp" {
		title = "Capture paused"
	}
	message := sanitize(arming.blockedMessage())
	button := badgeStyle(colorYellow) + action + sgrReset
	if arming.State != "detached" || cols < len(action)+12 {
		return []string{bannerNotice(title, message, cols)}
	}
	if !tall {
		// One row: the notice, and the button at the right.
		w := cols - len(action) - 1
		v.bannerHits = append(v.bannerHits, boxHit{row: top, x0: w + 2, x1: w + 1 + len(action), act: func(int) { v.relaunch() }})
		return []string{bannerNotice(title, message, w) + " " + button}
	}
	v.bannerHits = append(v.bannerHits, boxHit{row: top + 1, x0: 3, x1: 2 + len(action), act: func(int) { v.relaunch() }})
	second := sgrYellow + "▌" + sgrReset + " " + button
	if v.offersAutoReattach() {
		x := 2 + len(action) + 4
		if x+toggleCells+len(auto) <= cols {
			second += "   " + toggleSwitch(v.autoReattach, false) + " " + auto
			v.bannerHits = append(v.bannerHits, boxHit{row: top + 1, x0: x, x1: x + toggleCells + len(auto), act: func(int) { v.toggleAutoReattach() }})
		}
	}
	return []string{bannerNotice(title, message, cols), padStyled(second, cols)}
}

// statusColor is NetworkFormatting.statusColor on the theme's colors.
func statusColor(t netTransaction) string {
	switch {
	case t.Error != "":
		return sgrRed
	case t.StatusCode == nil:
		return sgrDim
	case *t.StatusCode >= 200 && *t.StatusCode < 300:
		return sgrGreen
	case *t.StatusCode >= 300 && *t.StatusCode < 400:
		return "\x1b[" + colorBlue + "m"
	case *t.StatusCode >= 400 && *t.StatusCode < 500:
		return sgrYellow
	}
	return sgrRed
}

// listColumn draws the request list w cells wide and n rows tall: the column headers, then the
// requests (or the chooser or an empty state).
func (v *netViewer) listColumn(w, n int) []string {
	out := make([]string, 0, n)
	if w <= 0 {
		for len(out) < n {
			out = append(out, "")
		}
		return out
	}
	// Columns: the override mark, Status, Method, Host, Path (what is left), Size and Time. Path
	// is what tells requests apart, so the narrower the list, the more of the others it leaves
	// out to keep it readable: Size first, then Host, then Time.
	const markW, statusW, methodW, sizeW, timeW, pathMin = 2, 7, 8, 10, 9, 28
	pathW := w - markW - statusW - methodW
	hostW, showTime, showSize := 0, false, false
	if pathW-timeW >= pathMin {
		showTime, pathW = true, pathW-timeW
	}
	if h := min(30, max(20, w/5)); pathW-h-1 >= pathMin+8 {
		hostW, pathW = h, pathW-h-1
	}
	if pathW-sizeW >= pathMin+16 {
		showSize, pathW = true, pathW-sizeW
	}
	pathW = max(0, pathW)
	// cells lays a row out; style colors each cell (it gets the column's index).
	cells := func(style func(col int) string, values ...string) string {
		if pathW < 4 { // too narrow for columns: the status, method and path in a row
			return style(1) + fit(values[1]+" "+values[2]+" "+values[4], w) + sgrReset
		}
		widths := []int{markW, statusW, methodW, hostW, pathW, sizeW, timeW}
		shown := []bool{true, true, true, hostW > 0, true, showSize, showTime}
		var s strings.Builder
		for i, value := range values {
			if !shown[i] {
				continue
			}
			text := fit(value, widths[i])
			switch i {
			case 3:
				text = fit(value, widths[i]) + " "
			case 4:
				text = fit(clipMiddle(value, widths[i]), widths[i])
			}
			if st := style(i); st != "" {
				text = st + text + sgrReset
			}
			s.WriteString(text)
		}
		return padStyled(s.String(), w)
	}
	// The headers are quiet, and in the accent while the list has the keys beside an open detail.
	headerStyle := sgrBold + tertiaryStyle
	switch {
	case v.detail && v.detailFocus:
		headerStyle = tertiaryStyle
	case v.detail:
		headerStyle = sectionStyle
	}
	out = append(out, cells(func(int) string { return headerStyle }, "", "STATUS", "METHOD", "HOST", "PATH", " SIZE", " TIME"))

	room := n - 1
	v.chooserHits = v.chooserHits[:0]
	switch {
	case v.showsChooser():
		out = v.chooserRows(out, w, n)
	case len(v.visible) == 0:
		text := "Capture stopped"
		switch {
		case !v.opened && v.err == "":
			text = "Connecting…"
		case v.state.IsConnecting:
			text = "Connecting…"
		case v.state.IsRunning:
			text = "Waiting for traffic…"
		}
		out = append(out, strings.Repeat(" ", w))
		if len(out) < n {
			out = append(out, sgrDim+fit("  "+text, w)+sgrReset)
		}
	default:
		// Follows new requests until one is selected or the list is scrolled by hand.
		limit := max(0, len(v.visible)-room)
		row := v.selectedRow()
		switch {
		case v.scrolled:
		case row < 0:
			v.top = limit
		case row < v.top:
			v.top = row
		case row >= v.top+room:
			v.top = row - room + 1
		}
		v.top = max(0, min(v.top, limit))
		first, last, selected := v.selection()
		for i := v.top; i < len(v.visible) && i < v.top+room; i++ {
			t := v.txns[v.visible[i]]
			size, elapsed := formatNetSize(t.ResponseBytes), formatNetDuration(t.duration())
			badge := v.badge(t)
			mark, markStyle := "", ""
			switch badge.kind {
			case "applied":
				mark, markStyle = "↯", sgrYellow
			case "willApply":
				mark, markStyle = "↯", sgrDim
			case "blocked":
				mark, markStyle = "!", sgrYellow
			}
			status := statusColor(t)
			if badge.kind == "applied" {
				status = sgrYellow
			}
			row := cells(func(col int) string {
				switch col {
				case 0:
					return markStyle
				case 1:
					return status + sgrBold
				case 2, 3:
					return secondaryStyle
				case 5, 6:
					return tertiaryStyle
				}
				return ""
			}, mark, t.statusText(), t.Method, sanitize(t.Host), sanitize(t.path()), " "+size, " "+elapsed)
			if selected && i >= first && i <= last {
				// Every selected request is on the selection color, the cursor's in bold; the
				// colors of its cells stay, so its status still reads. Quieter while the detail
				// has the keys.
				style := selectedRowStyle
				if v.detail && v.detailFocus {
					style = inactiveRowStyle
				}
				if t.ID == v.selectedID {
					style += sgrBold
				}
				row = onRow(row, style, w)
			}
			out = append(out, row)
		}
	}
	for len(out) < n {
		out = append(out, strings.Repeat(" ", w))
	}
	return out
}

// padStyled fills a styled row out to w cells.
func padStyled(s string, w int) string {
	return s + strings.Repeat(" ", max(0, w-cellWidth(stripSGR(s))))
}

// wrapCells breaks text into lines of at most w cells, at line breaks first.
func wrapCells(text string, w int) []string {
	if w <= 0 {
		return nil
	}
	var out []string
	for _, para := range strings.Split(text, "\n") {
		para = sanitize(strings.TrimRight(para, "\r"))
		if para == "" {
			out = append(out, "")
			continue
		}
		var b strings.Builder
		used, prev := 0, 0
		for _, r := range para {
			rw := widthAfter(r, prev)
			if used+rw > w {
				out = append(out, b.String())
				b.Reset()
				used = 0
			}
			b.WriteRune(r)
			used += rw
			prev = runeWidth(r)
		}
		out = append(out, b.String())
	}
	return out
}

// bodyText is the body the Request or Response tab shows (NetworkFormatting.bodyText).
func (v *netViewer) bodyText(t netTransaction, request bool) string {
	b := v.bodies[t.ID]
	switch {
	case b == nil:
		return ""
	case request:
		return netBodyText(b.Request, t.requestContentType())
	}
	return netBodyText(b.Response, t.ResponseContentType)
}

// detailLines is the selected request's detail for the open tab, w cells wide, with what a
// click does on the lines that are buttons.
func (v *netViewer) detailLines(t netTransaction, w int) (lines []string, meta []detailLine) {
	// add appends a content line. value is what the line shows part of (a field's value, a
	// body), valueX the cell it starts at, and cont marks a line a long value wrapped onto.
	add := func(line, value string, valueX int, cont bool) {
		lines = append(lines, line)
		meta = append(meta, detailLine{value: value, valueX: valueX, cont: cont})
	}
	plain := func(line string) { add(line, "", 0, false) }
	labelW := min(20, max(1, w/2))
	field := func(label, value string) {
		for i, part := range wrapCells(value, max(1, w-labelW)) {
			head := strings.Repeat(" ", labelW)
			if i == 0 {
				head = sgrDim + fit(strings.ToUpper(label), labelW) + sgrReset
			}
			add(head+part, value, labelW, i > 0)
		}
	}
	// button puts a copy button at the right of a line that starts with left, in the style of
	// the popups' close button.
	button := func(left, label string, act func()) {
		label = " " + label + " "
		room := w - cellWidth(stripSGR(left)) - len(label)
		if room < 1 {
			left, room = "", max(0, w-len(label))
		}
		plain(left + strings.Repeat(" ", room) + closeButton(label))
		meta[len(meta)-1].act, meta[len(meta)-1].x0, meta[len(meta)-1].x1 = act, room+cellWidth(stripSGR(left)), w-1
	}
	body := func(request bool) {
		text := v.bodyText(t, request)
		if text == "" {
			plain(sgrDim + "No body." + sgrReset)
			return
		}
		button("", "Copy", func() { v.copy(text) })
		plain("")
		for _, para := range strings.Split(text, "\n") {
			for i, part := range wrapCells(para, w) {
				add(part, text, 0, i > 0)
			}
		}
	}
	headers := func(title string, list []headerPair) {
		var text []string
		for _, h := range list {
			text = append(text, h.Name+": "+h.Value)
		}
		heading := sgrDim + strings.ToUpper(title) + sgrReset
		if len(list) == 0 {
			plain(heading)
			plain("—")
			plain("")
			return
		}
		button(heading, "Copy "+title, func() { v.copy(strings.Join(text, "\n")) })
		nameW := min(28, w/3)
		for _, h := range list {
			for i, part := range wrapCells(h.Value, max(1, w-nameW-1)) {
				head := strings.Repeat(" ", nameW+1)
				if i == 0 {
					head = sgrCyan + fit(sanitize(h.Name), nameW) + sgrReset + " "
				}
				add(head+part, h.Value, nameW+1, i > 0)
			}
		}
		plain("")
	}
	clock := func(at time.Time) string { return at.Local().Format("15:04:05") }

	switch v.tab {
	case tabOverview:
		status := "—"
		switch {
		case t.Error != "":
			status = t.Error
		case t.StatusCode != nil:
			status = fmt.Sprint(*t.StatusCode)
		}
		contentType := t.ResponseContentType
		if contentType == "" {
			contentType = "—"
		}
		field("URL", t.URL)
		field("Method", t.Method)
		field("Status", status)
		field("Content-Type", contentType)
		field("Request size", formatNetSize(t.RequestBytes))
		field("Response size", formatNetSize(t.ResponseBytes))
		field("Duration", formatNetDuration(t.duration()))
	case tabHeaders:
		headers("Request Headers", t.displayRequestHeaders())
		headers("Response Headers", t.displayResponseHeaders())
	case tabRequest:
		body(true)
	case tabResponse:
		body(false)
	case tabTiming:
		finished := "—"
		if t.FinishedAt != nil {
			finished = clock(*t.FinishedAt)
		}
		field("Started", clock(t.StartedAt))
		field("Time to first byte", formatNetDuration(t.ttfb()))
		field("Finished", finished)
		field("Total duration", formatNetDuration(t.duration()))
	}
	return lines, meta
}

// detailColumn draws the detail pane w cells wide and n rows tall: the request and the close
// button, the tabs, then the open tab's content.
func (v *netViewer) detailColumn(w, n int) []string {
	out := make([]string, 0, n)
	t, ok := v.selected()
	x := v.listW + 1 // the pane's first column on screen
	if v.listW > 0 {
		x++
	}
	v.closeX0, v.closeX1, v.tabHits, v.detailMeta, v.detailDrawn, v.detailText = 0, 0, v.tabHits[:0], nil, nil, nil
	v.detailX = x + 1
	if w < len(escClose)+4 {
		for len(out) < n {
			out = append(out, "")
		}
		return out
	}
	title := ""
	if ok {
		title = t.Method + " " + sanitize(t.path())
	}
	// The title is in the accent while the detail has the keys.
	label, titleStyle := escClose, sgrBold
	if v.detailFocus {
		titleStyle = sectionStyle
	}
	titleW := w - len(label) - 2
	v.closeX0, v.closeX1 = x+1+titleW, x+titleW+len(label)
	out = append(out, " "+titleStyle+fit(title, titleW)+sgrReset+closeButton(label)+" ")

	var tabs strings.Builder
	used := 1
	tabs.WriteString(" ")
	for i, name := range netTabs {
		if used+len(name)+3 > w {
			break
		}
		style := ""
		if i == v.tab {
			style = sgrBold + sgrRev
		}
		tabs.WriteString(style + " " + name + " " + sgrReset + " ")
		v.tabHits = append(v.tabHits, hit{x0: x + used, x1: x + used + len(name) + 1, act: func() { v.setTab(i) }})
		used += len(name) + 3
	}
	// Copy cURL sits at the row's right end, as in the app, when the tabs leave it room.
	if curl := " Copy cURL "; ok && used+len(curl)+1 <= w {
		gap := w - used - len(curl) - 1
		tabs.WriteString(strings.Repeat(" ", gap) + closeButton(curl) + " ")
		v.tabHits = append(v.tabHits, hit{x0: x + used + gap, x1: x + used + gap + len(curl) - 1, act: func() { v.copyCurl(t) }})
		used = w
	}
	out = append(out, tabs.String()+strings.Repeat(" ", max(0, w-used)), strings.Repeat(" ", w))

	v.detailFirst = v.listTop - 1 + len(out)
	room := n - len(out)
	if !ok {
		out = append(out, " "+sgrDim+fit("Select a request to inspect it.", w-1)+sgrReset)
	} else {
		lines, meta := v.detailLines(t, w-2)
		out = append(out, v.detailRows(lines, meta, w, room)...)
		v.detailText = make([]string, len(lines))
		for i, line := range lines {
			v.detailText[i] = stripSGR(line)
		}
	}
	for len(out) < n {
		out = append(out, strings.Repeat(" ", w))
	}
	return out
}

// statusBar is the app's: a dot for the capture, the request count, and the device at the right,
// with Help beside it.
func (v *netViewer) statusBar(cols int) string {
	if cols < 2 {
		return ""
	}
	dot := sgrDim
	if v.state.IsRunning {
		dot = sgrGreen
	}
	count := clip(fmt.Sprintf("%d requests", len(v.txns)), max(0, cols-2))
	used := 2 + cellWidth(count)
	name := clip(sanitize(v.device.displayModel()), max(0, cols-used-2))
	const help, gap = "Help", 3
	button := ""
	v.helpX0, v.helpX1 = 0, 0
	if cols-used-cellWidth(name)-len(help)-gap >= 2 {
		button = sgrUnder + help + sgrReset + strings.Repeat(" ", gap)
		v.helpX0 = cols - cellWidth(name) - gap - len(help) + 1
		v.helpX1 = v.helpX0 + len(help) - 1
	}
	pad := strings.Repeat(" ", max(0, cols-used-cellWidth(name)-cellWidth(stripSGR(button))))
	return dot + "●" + sgrReset + " " + sgrDim + count + sgrReset + pad + button + sgrDim + name + sgrReset
}

// appPicker is the app's installed-apps list for choosing what to inspect: a search field over
// the apps, user apps first.
type appPicker struct {
	apps     []appEntry
	loading  bool
	query    textInput
	selected int
	top      int // as last drawn: the screen row of the first app,
	start    int // and that app's index
}

// open shows the list and fetches it again, so a failed listing is retried by reopening.
func (a *appPicker) open(p *pane, deviceID string) {
	if !a.begin() {
		return
	}
	go func() {
		var list []appEntry
		_ = p.c.Call("devices.apps", map[string]any{"deviceID": deviceID}, &list)
		p.post(func() { a.loaded(list) })
	}()
}

// begin resets the search for a newly shown list. False when a listing is already in flight,
// so the caller starts no other.
func (a *appPicker) begin() bool {
	a.query.set("")
	a.selected = 0
	if a.loading {
		return false
	}
	a.loading = true
	return true
}

// loaded takes a listing: user apps first, then by name.
func (a *appPicker) loaded(list []appEntry) {
	a.loading = false
	if len(list) == 0 {
		return // keep the last list when a refresh comes back empty
	}
	sort.SliceStable(list, func(i, j int) bool {
		if list[i].IsUserApp != list[j].IsUserApp {
			return list[i].IsUserApp
		}
		return strings.ToLower(list[i].display()) < strings.ToLower(list[j].display())
	})
	a.apps = list
}

func (a *appPicker) filtered() []appEntry {
	q := strings.ToLower(a.query.String())
	if q == "" {
		return a.apps
	}
	var out []appEntry
	for _, app := range a.apps {
		if strings.Contains(strings.ToLower(app.ID), q) || strings.Contains(strings.ToLower(app.display()), q) {
			out = append(out, app)
		}
	}
	return out
}

// key returns the chosen app's id, or done when the list was dismissed.
func (a *appPicker) key(k []byte) (pkg string, done bool) {
	apps := a.filtered()
	switch {
	case isEsc(k):
		return "", true
	case isArrowUp(k):
		a.selected = clampIndex(a.selected-1, len(apps))
	case isArrowDown(k):
		a.selected = clampIndex(a.selected+1, len(apps))
	case isEnter(k):
		if a.selected < len(apps) {
			return apps[a.selected].ID, true
		}
	default:
		if a.query.handle(k) {
			a.selected = 0
		}
	}
	return "", false
}

func (a *appPicker) mouse(m mouseEvent) (pkg string, done bool) {
	apps := a.filtered()
	switch {
	case m.button == 64:
		a.selected = clampIndex(a.selected-1, len(apps))
	case m.button == 65:
		a.selected = clampIndex(a.selected+1, len(apps))
	case m.button == 0 && m.y >= a.top && a.start+m.y-a.top < len(apps):
		return apps[a.start+m.y-a.top].ID, true
	}
	return "", false
}

func (a *appPicker) frame(rows, cols int) []string {
	var frame []string
	head := 2
	if toolbarRows(rows) == 3 && cols >= 12 {
		box := boxedField(&a.query, "Search apps…", true, cols, "")
		frame = append(frame, box[0], box[1], box[2])
		head = 4
	} else {
		frame = append(frame, renderField(&a.query, "Search apps…", true, min(cols, 40), sgrUnder))
	}
	frame = append(frame, "")
	a.top = head + 1
	apps := a.filtered()
	if a.loading && len(a.apps) == 0 {
		return append(frame, sgrDim+"…"+sgrReset)
	}
	a.selected = clampIndex(a.selected, len(apps))
	room := max(1, rows-head-1)
	a.start = listWindow(a.selected, room)
	for i := a.start; i < len(apps) && i < a.start+room; i++ {
		app := apps[i]
		dot := "  "
		if app.IsUserApp {
			dot = sgrGreen + "•" + sgrReset + " "
		}
		title := clip(sanitize(app.display()), max(0, cols-4))
		subtitle := ""
		if rest := cols - 4 - cellWidth(title) - 2; app.Name != nil && rest > 0 {
			subtitle = "  " + sgrDim + clip(sanitize(app.ID), rest) + sgrReset
		}
		frame = append(frame, listRow(dot+title+subtitle, i == a.selected, cols))
	}
	return frame
}
