package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"
)

// The override rule model and its wire format (Sources/Core/Overrides/OverrideRule.swift), as
// overrides.state publishes it and overrides.save takes it.
//
// Decoding follows the Swift decoders: only a rule's id is required, a missing or null key
// takes the Swift default, and an unknown action or body kind falls back to respond or none.
// Encoding writes every key the app writes, so a rule this client only partly shows (mapRemote,
// removeHeaders, scope, file bodies) goes back to the daemon as it came.

// bodyRef mirrors OverrideBodyRef: where a rule's payload lives. Kind is "none", "inline"
// (Text), "blob" (Filename, under bodies/ in the override directory) or "file" (Path, Watch).
// The zero value is none.
type bodyRef struct {
	Kind, Text, Filename, Path string
	Watch                      bool
}

// inlineBodyLimit is OverrideBodyRef.inlineLimit: above this a new body is written as a blob.
const inlineBodyLimit = 4096

func (b bodyRef) MarshalJSON() ([]byte, error) {
	switch b.Kind {
	case "inline":
		return json.Marshal(struct {
			Kind string `json:"kind"`
			Text string `json:"text"`
		}{"inline", b.Text})
	case "blob":
		return json.Marshal(struct {
			Kind     string `json:"kind"`
			Filename string `json:"filename"`
		}{"blob", b.Filename})
	case "file":
		return json.Marshal(struct {
			Kind  string `json:"kind"`
			Path  string `json:"path"`
			Watch bool   `json:"watch"`
		}{"file", b.Path, b.Watch})
	}
	return []byte(`{"kind":"none"}`), nil
}

func (b *bodyRef) UnmarshalJSON(data []byte) error {
	var raw struct {
		Kind, Text, Filename, Path *string
		Watch                      *bool
	}
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}
	*b = bodyRef{Kind: "none"}
	switch stringOr(raw.Kind, "none") {
	case "inline":
		*b = bodyRef{Kind: "inline", Text: stringOr(raw.Text, "")}
	case "blob":
		// A blob or file without its name is no body at all.
		if name := stringOr(raw.Filename, ""); name != "" {
			*b = bodyRef{Kind: "blob", Filename: name}
		}
	case "file":
		if path := stringOr(raw.Path, ""); path != "" {
			*b = bodyRef{Kind: "file", Path: path, Watch: raw.Watch == nil || *raw.Watch}
		}
	}
	return nil
}

// isNone reports whether the rule has no body.
func (b bodyRef) isNone() bool { return b.Kind == "" || b.Kind == "none" }

// respondSpec mirrors OverrideResponseSpec: a response Jaca makes up.
type respondSpec struct {
	StatusCode int
	Headers    []headerPair
	Body       bodyRef
}

// defaultRespondSpec is OverrideResponseSpec(): 200, JSON content type, no body.
func defaultRespondSpec() respondSpec {
	return respondSpec{
		StatusCode: 200,
		Headers:    []headerPair{{Name: "Content-Type", Value: "application/json"}},
		Body:       bodyRef{Kind: "none"},
	}
}

func (s respondSpec) MarshalJSON() ([]byte, error) {
	return json.Marshal(struct {
		StatusCode int          `json:"statusCode"`
		Headers    []headerPair `json:"headers"`
		Body       bodyRef      `json:"body"`
	}{s.StatusCode, emptyIfNil(s.Headers), s.Body})
}

func (s *respondSpec) UnmarshalJSON(data []byte) error {
	var raw struct {
		StatusCode *int
		Headers    *[]headerPair
		Body       *bodyRef
	}
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}
	*s = defaultRespondSpec()
	if raw.StatusCode != nil {
		s.StatusCode = *raw.StatusCode
	}
	if raw.Headers != nil {
		s.Headers = *raw.Headers
	}
	if raw.Body != nil {
		s.Body = *raw.Body
	}
	return nil
}

// responseEdit mirrors ResponseEdit: a rewrite of the origin's real response. A nil StatusCode
// or Body keeps the origin's. HeaderMode is "merge" or "replace".
type responseEdit struct {
	StatusCode    *int
	HeaderMode    string
	Headers       []headerPair
	RemoveHeaders []string
	Body          *bodyRef
}

func (e responseEdit) MarshalJSON() ([]byte, error) {
	mode := e.HeaderMode
	if mode == "" {
		mode = "merge"
	}
	return json.Marshal(struct {
		StatusCode    *int         `json:"statusCode,omitempty"`
		HeaderMode    string       `json:"headerMode"`
		Headers       []headerPair `json:"headers"`
		RemoveHeaders []string     `json:"removeHeaders"`
		Body          *bodyRef     `json:"body,omitempty"`
	}{e.StatusCode, mode, emptyIfNil(e.Headers), emptyIfNil(e.RemoveHeaders), e.Body})
}

func (e *responseEdit) UnmarshalJSON(data []byte) error {
	var raw struct {
		StatusCode    *int
		HeaderMode    *string
		Headers       *[]headerPair
		RemoveHeaders *[]string
		Body          *bodyRef
	}
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}
	mode := stringOr(raw.HeaderMode, "merge")
	if mode != "merge" && mode != "replace" {
		// The app fails the rule on a header mode it doesn't know; so does this.
		return fmt.Errorf("unknown header mode %q", mode)
	}
	*e = responseEdit{StatusCode: raw.StatusCode, HeaderMode: mode, Body: raw.Body}
	if raw.Headers != nil {
		e.Headers = *raw.Headers
	}
	if raw.RemoveHeaders != nil {
		e.RemoveHeaders = *raw.RemoveHeaders
	}
	return nil
}

// ruleAction mirrors OverrideActionSpec: what a rule does when it matches. Kind is "respond"
// (Respond), "editResponse" (Edit) or "mapRemote" (MapRemote, a URL). Only the field for Kind
// means anything. The zero value encodes as respond.
type ruleAction struct {
	Kind      string
	Respond   respondSpec
	Edit      responseEdit
	MapRemote string
}

func (a ruleAction) MarshalJSON() ([]byte, error) {
	switch a.Kind {
	case "editResponse":
		return json.Marshal(struct {
			Kind string       `json:"kind"`
			Edit responseEdit `json:"editResponse"`
		}{"editResponse", a.Edit})
	case "mapRemote":
		return json.Marshal(struct {
			Kind string `json:"kind"`
			URL  string `json:"mapRemote"`
		}{"mapRemote", a.MapRemote})
	}
	return json.Marshal(struct {
		Kind    string      `json:"kind"`
		Respond respondSpec `json:"respond"`
	}{"respond", a.Respond})
}

func (a *ruleAction) UnmarshalJSON(data []byte) error {
	var raw struct {
		Kind         *string
		Respond      *respondSpec
		EditResponse *responseEdit
		MapRemote    *string
	}
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}
	switch stringOr(raw.Kind, "respond") {
	case "editResponse":
		*a = ruleAction{Kind: "editResponse", Edit: responseEdit{HeaderMode: "merge"}}
		if raw.EditResponse != nil {
			a.Edit = *raw.EditResponse
		}
	case "mapRemote":
		*a = ruleAction{Kind: "mapRemote", MapRemote: stringOr(raw.MapRemote, "")}
	default:
		*a = ruleAction{Kind: "respond", Respond: defaultRespondSpec()}
		if raw.Respond != nil {
			a.Respond = *raw.Respond
		}
	}
	return nil
}

// Capabilities are InterceptCapabilities' bits: what a capture can do with a matching rule.
// netState.InterceptCapabilities carries them.
const (
	capShortCircuit = 1 << iota // answer without contacting the origin
	capEditResponse             // fetch the real response and rewrite it
	capDelay                    // hold a response back
	capBodies                   // sees request and response bodies
	capMapRemote                // repoint a request at another origin
	capSuspend                  // pause an exchange for editing

	capDesktopTerminated = capShortCircuit | capEditResponse | capDelay | capBodies
)

// requiredCapabilities is OverrideActionSpec.requiredCapabilities.
func (a ruleAction) requiredCapabilities() int {
	switch a.Kind {
	case "editResponse":
		return capEditResponse | capBodies
	case "mapRemote":
		return capMapRemote
	}
	return capShortCircuit
}

// body is the body the action serves, nil when it has none to load (an edit that keeps the
// origin's body, or mapRemote).
func (a ruleAction) body() *bodyRef {
	switch a.Kind {
	case "editResponse":
		return a.Edit.Body
	case "mapRemote":
		return nil
	}
	return &a.Respond.Body
}

// ruleMatcher mirrors OverrideMatcher. Kind is "glob" or "regex"; "" reads as glob. Methods is
// a set, empty meaning any method.
type ruleMatcher struct {
	Pattern string
	Kind    string
	Methods []string
}

func (m ruleMatcher) MarshalJSON() ([]byte, error) {
	kind := m.Kind
	if kind == "" {
		kind = "glob"
	}
	return json.Marshal(struct {
		Pattern string   `json:"pattern"`
		Kind    string   `json:"kind"`
		Methods []string `json:"methods"`
	}{m.Pattern, kind, emptyIfNil(m.Methods)})
}

func (m *ruleMatcher) UnmarshalJSON(data []byte) error {
	var raw struct {
		Pattern *string
		Kind    *string
		Methods *[]string
	}
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}
	kind := stringOr(raw.Kind, "glob")
	if kind != "glob" && kind != "regex" {
		// The app fails the rule on a matcher kind it doesn't know; so does this.
		return fmt.Errorf("unknown matcher kind %q", kind)
	}
	*m = ruleMatcher{Pattern: stringOr(raw.Pattern, ""), Kind: kind}
	if raw.Methods != nil {
		m.Methods = *raw.Methods
	}
	return nil
}

// ruleScope mirrors OverrideScope: the devices and apps a rule applies to. Both are sets, and
// an empty one means any.
type ruleScope struct {
	DeviceIDs, AppIDs []string
}

func (s ruleScope) MarshalJSON() ([]byte, error) {
	return json.Marshal(struct {
		DeviceIDs []string `json:"deviceIDs"`
		AppIDs    []string `json:"appIDs"`
	}{emptyIfNil(s.DeviceIDs), emptyIfNil(s.AppIDs)})
}

// matches is OverrideScope.matches. An empty deviceID or appID is an unknown one, which only
// an unscoped rule accepts.
func (s ruleScope) matches(deviceID, appID string) bool {
	if len(s.DeviceIDs) > 0 && (deviceID == "" || !containsString(s.DeviceIDs, deviceID)) {
		return false
	}
	if len(s.AppIDs) > 0 && (appID == "" || !containsString(s.AppIDs, appID)) {
		return false
	}
	return true
}

// overrideRule mirrors OverrideRule. ID is an uppercase UUID. CreatedAt is the ISO-8601 text
// the daemon sent, kept as text so saving a rule doesn't change it. RoutedHosts is a set: the
// only hosts the rule sends through the Mac. GroupID is the uppercase UUID of the group the
// rule is in, "" for none; it goes back on save, so editing a rule keeps it in its group.
type overrideRule struct {
	ID, Name    string
	Enabled     bool
	Matcher     ruleMatcher
	Scope       ruleScope
	Action      ruleAction
	DelayMillis int
	CreatedAt   string
	RoutedHosts []string // wire: divertHosts
	GroupID     string
}

// newOverrideRule is OverrideRule(): a new id, enabled, an empty glob, a 200 JSON response with
// no body, created now.
func newOverrideRule() overrideRule {
	return overrideRule{
		ID:        newUUID(),
		Enabled:   true,
		Matcher:   ruleMatcher{Kind: "glob"},
		Action:    ruleAction{Kind: "respond", Respond: defaultRespondSpec()},
		CreatedAt: wireDate(time.Now()),
	}
}

// displayName is what a rule is called when the user hasn't named it.
func (r overrideRule) displayName() string {
	if r.Name != "" {
		return r.Name
	}
	if r.Matcher.Pattern == "" {
		return "Untitled override"
	}
	return r.Matcher.Pattern
}

func (r overrideRule) MarshalJSON() ([]byte, error) {
	created := r.CreatedAt
	if created == "" {
		created = wireDate(time.Now())
	}
	return json.Marshal(struct {
		ID          string      `json:"id"`
		Name        string      `json:"name"`
		Enabled     bool        `json:"enabled"`
		Matcher     ruleMatcher `json:"matcher"`
		Scope       ruleScope   `json:"scope"`
		Action      ruleAction  `json:"action"`
		DelayMillis int         `json:"delayMillis"`
		CreatedAt   string      `json:"createdAt"`
		RoutedHosts []string    `json:"divertHosts"`
		GroupID     string      `json:"groupID,omitempty"`
	}{r.ID, r.Name, r.Enabled, r.Matcher, r.Scope, r.Action, r.DelayMillis, created, emptyIfNil(r.RoutedHosts), r.GroupID})
}

func (r *overrideRule) UnmarshalJSON(data []byte) error {
	var raw struct {
		ID          *string
		Name        *string
		Enabled     *bool
		Matcher     *ruleMatcher
		Scope       *ruleScope
		Action      *ruleAction
		DelayMillis *int
		CreatedAt   json.RawMessage
		DivertHosts *[]string
		GroupID     *string
	}
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}
	if raw.ID == nil || !isUUID(*raw.ID) {
		return errors.New("override rule without a valid id")
	}
	*r = overrideRule{
		ID:        strings.ToUpper(*raw.ID),
		Name:      stringOr(raw.Name, ""),
		Enabled:   raw.Enabled == nil || *raw.Enabled,
		Matcher:   ruleMatcher{Kind: "glob"},
		Action:    ruleAction{Kind: "respond", Respond: defaultRespondSpec()},
		CreatedAt: decodeWireDate(raw.CreatedAt),
	}
	if raw.Matcher != nil {
		r.Matcher = *raw.Matcher
	}
	if raw.Scope != nil {
		r.Scope = *raw.Scope
	}
	if raw.Action != nil {
		r.Action = *raw.Action
	}
	if raw.DelayMillis != nil {
		r.DelayMillis = *raw.DelayMillis
	}
	if raw.DivertHosts != nil {
		r.RoutedHosts = *raw.DivertHosts
	}
	// A group id that is no UUID names no group: the rule is ungrouped, not lost.
	if id := stringOr(raw.GroupID, ""); isUUID(id) {
		r.GroupID = strings.ToUpper(id)
	}
	return nil
}

// overrideGroup mirrors OverrideGroup: a folder of rules, with a switch over all of them. ID is
// an uppercase UUID; CreatedAt is kept as the daemon's text, as a rule's is.
type overrideGroup struct {
	ID, Name  string
	Enabled   bool
	CreatedAt string
}

// newOverrideGroup is a new group: a new id, enabled, created now.
func newOverrideGroup(name string) overrideGroup {
	return overrideGroup{ID: newUUID(), Name: name, Enabled: true, CreatedAt: wireDate(time.Now())}
}

// displayName is what a group is called when the user hasn't named it.
func (g overrideGroup) displayName() string {
	if g.Name != "" {
		return g.Name
	}
	return "Untitled group"
}

func (g overrideGroup) MarshalJSON() ([]byte, error) {
	created := g.CreatedAt
	if created == "" {
		created = wireDate(time.Now())
	}
	return json.Marshal(struct {
		ID        string `json:"id"`
		Name      string `json:"name"`
		Enabled   bool   `json:"enabled"`
		CreatedAt string `json:"createdAt"`
	}{g.ID, g.Name, g.Enabled, created})
}

// UnmarshalJSON requires only the id, as the rule's does.
func (g *overrideGroup) UnmarshalJSON(data []byte) error {
	var raw struct {
		ID        *string
		Name      *string
		Enabled   *bool
		CreatedAt json.RawMessage
	}
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}
	if raw.ID == nil || !isUUID(*raw.ID) {
		return errors.New("override group without a valid id")
	}
	*g = overrideGroup{
		ID:        strings.ToUpper(*raw.ID),
		Name:      stringOr(raw.Name, ""),
		Enabled:   raw.Enabled == nil || *raw.Enabled,
		CreatedAt: decodeWireDate(raw.CreatedAt),
	}
	return nil
}

// wireDate formats a time as DaemonDates does: ISO-8601 in UTC with milliseconds.
func wireDate(t time.Time) string {
	return t.UTC().Format("2006-01-02T15:04:05.000Z")
}

// decodeWireDate reads a rule's createdAt. The date is cosmetic and must not cost a rule, so
// text is kept as it is, a number is seconds since 1970 (the daemon's other accepted form),
// and anything else is now.
func decodeWireDate(raw json.RawMessage) string {
	var text string
	if json.Unmarshal(raw, &text) == nil && text != "" {
		return text
	}
	var seconds float64
	if len(raw) > 0 && json.Unmarshal(raw, &seconds) == nil && string(raw) != "null" {
		return wireDate(time.Unix(0, int64(seconds*1e9)))
	}
	return wireDate(time.Now())
}

// armingState mirrors InterceptArmingState's wire format (InterceptWire.swift): what a capture
// reports about its armed transport. State is "idle", "waitingForAgent", "agentTooOld",
// "waitingForApp" (AppID), "detached" (AppID), "active" (Port, Hosts) or "failed" (Message).
// An unknown state from a newer build, and the zero value, read as idle.
type armingState struct {
	State, AppID string
	Port         int
	Hosts        []string
	Message      string
}

var idleArming = armingState{State: "idle"}

func (a armingState) MarshalJSON() ([]byte, error) {
	a = a.normalized()
	out := map[string]any{"state": a.State}
	switch a.State {
	case "waitingForApp", "detached":
		out["appID"] = a.AppID
	case "active":
		hosts := append([]string{}, a.Hosts...)
		sort.Strings(hosts)
		out["port"], out["hosts"] = a.Port, hosts
	case "failed":
		out["message"] = a.Message
	}
	return json.Marshal(out)
}

// UnmarshalJSON never fails: a state this client can't read is idle, "nothing armed here".
func (a *armingState) UnmarshalJSON(data []byte) error {
	var raw struct {
		State, AppID *string
		Port         *int
		Hosts        *[]string
		Message      *string
	}
	*a = idleArming
	if json.Unmarshal(data, &raw) != nil {
		return nil
	}
	read := armingState{State: stringOr(raw.State, ""), AppID: stringOr(raw.AppID, ""), Message: stringOr(raw.Message, "")}
	if raw.Port != nil {
		read.Port = *raw.Port
	}
	if raw.Hosts != nil {
		read.Hosts = *raw.Hosts
	}
	*a = read.normalized()
	return nil
}

// normalized keeps only the fields the state carries, so two readings of one state compare
// equal.
func (a armingState) normalized() armingState {
	switch a.State {
	case "waitingForAgent", "agentTooOld":
		return armingState{State: a.State}
	case "waitingForApp", "detached":
		return armingState{State: a.State, AppID: a.AppID}
	case "active":
		return armingState{State: a.State, Port: a.Port, Hosts: a.Hosts}
	case "failed":
		return armingState{State: a.State, Message: a.Message}
	}
	return idleArming
}

// blockedMessage is InterceptArmingState.blockedMessage: the one sentence for each state where
// overrides are armed but doing nothing. "" for idle and active, which block nothing. A failed
// state says whatever the transport reported.
func (a armingState) blockedMessage() string {
	switch a.State {
	case "failed":
		return a.Message
	case "agentTooOld":
		return "This app has an older Jaca agent — rebuild it and restart capture."
	case "waitingForAgent":
		return "Arming — waiting for the agent to load in the app."
	case "waitingForApp":
		return "Open " + a.AppID + " to resume capturing."
	case "detached":
		return a.AppID + " is running without the Jaca agent — relaunch it to resume."
	}
	return ""
}

// interceptTarget mirrors InterceptTarget: one app on one device.
type interceptTarget struct {
	DeviceID string `json:"deviceID"`
	Package  string `json:"package"`
}

// overrideArming is one entry of overridesState.Armings.
type overrideArming = struct {
	Target interceptTarget
	State  armingState
}

// overridesState mirrors OverridesState, the value on overrides.state. HitCounts and LastHitAt
// are keyed by rule id; LastHitAt holds the daemon's ISO-8601 text. Groups are in display order,
// and Rules arrive in display and precedence order: group by group, then the ungrouped rules.
// HasGroups is whether the daemon sent groups at all: one from before groups sends none, and
// the pane then offers no group actions.
type overridesState struct {
	Rules         []overrideRule
	Groups        []overrideGroup
	HasGroups     bool
	MasterEnabled bool
	HitCounts     map[string]int
	LastHitAt     map[string]string
	Armings       []struct {
		Target interceptTarget
		State  armingState
	}
	LastActivity         string
	ReclaimedTunnelCount int
}

// UnmarshalJSON is as tolerant as OverridesState's decoder: a rule or arming that doesn't
// decode is skipped without losing the others, and any other field that is missing or
// malformed takes its default (the master switch defaults to on).
func (s *overridesState) UnmarshalJSON(data []byte) error {
	var raw struct {
		Rules, Groups, MasterEnabled, HitCounts, LastHitAt, Armings, LastActivity, ReclaimedTunnelCount json.RawMessage
	}
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}
	*s = overridesState{MasterEnabled: true, HitCounts: map[string]int{}, LastHitAt: map[string]string{}}
	s.Rules = decodeEach[overrideRule](raw.Rules)
	var groups []json.RawMessage
	s.HasGroups = len(raw.Groups) > 0 && json.Unmarshal(raw.Groups, &groups) == nil && groups != nil
	// A group listed twice is shown once, where it first appears.
	seen := map[string]bool{}
	for _, g := range decodeEach[overrideGroup](raw.Groups) {
		if !seen[g.ID] {
			seen[g.ID] = true
			s.Groups = append(s.Groups, g)
		}
	}
	for _, a := range decodeEach[struct {
		Target *interceptTarget
		State  *armingState
	}](raw.Armings) {
		// The app requires both keys of an arming.
		if a.Target != nil && a.State != nil {
			s.Armings = append(s.Armings, overrideArming{Target: *a.Target, State: *a.State})
		}
	}
	var master *bool
	if json.Unmarshal(raw.MasterEnabled, &master) == nil && master != nil {
		s.MasterEnabled = *master
	}
	var counts map[string]int
	if json.Unmarshal(raw.HitCounts, &counts) == nil && counts != nil {
		s.HitCounts = counts
	}
	var hits map[string]string
	if json.Unmarshal(raw.LastHitAt, &hits) == nil && hits != nil {
		s.LastHitAt = hits
	}
	_ = json.Unmarshal(raw.LastActivity, &s.LastActivity)
	var reclaimed int
	if json.Unmarshal(raw.ReclaimedTunnelCount, &reclaimed) == nil {
		s.ReclaimedTunnelCount = reclaimed
	}
	return nil
}

func (s overridesState) MarshalJSON() ([]byte, error) {
	type arming struct {
		Target interceptTarget `json:"target"`
		State  armingState     `json:"state"`
	}
	armings := make([]arming, 0, len(s.Armings))
	for _, a := range s.Armings {
		armings = append(armings, arming{a.Target, a.State})
	}
	counts, hits := s.HitCounts, s.LastHitAt
	if counts == nil {
		counts = map[string]int{}
	}
	if hits == nil {
		hits = map[string]string{}
	}
	// A state with no groups key (from an old daemon) encodes without one.
	var groups *[]overrideGroup
	if s.HasGroups || len(s.Groups) > 0 {
		list := emptyIfNil(s.Groups)
		groups = &list
	}
	return json.Marshal(struct {
		Rules                []overrideRule    `json:"rules"`
		Groups               *[]overrideGroup  `json:"groups,omitempty"`
		MasterEnabled        bool              `json:"masterEnabled"`
		HitCounts            map[string]int    `json:"hitCounts"`
		LastHitAt            map[string]string `json:"lastHitAt"`
		Armings              []arming          `json:"armings"`
		LastActivity         string            `json:"lastActivity,omitempty"`
		ReclaimedTunnelCount int               `json:"reclaimedTunnelCount"`
	}{emptyIfNil(s.Rules), groups, s.MasterEnabled, counts, hits, armings, s.LastActivity, s.ReclaimedTunnelCount})
}

// group is the listed group with this id.
func (s overridesState) group(id string) (overrideGroup, bool) {
	if id != "" {
		for _, g := range s.Groups {
			if g.ID == id {
				return g, true
			}
		}
	}
	return overrideGroup{}, false
}

// groupOf is the id of the group a rule is in, "" when it is in none. A groupID that names no
// listed group (or a daemon that sends no groups) leaves the rule ungrouped.
func (s overridesState) groupOf(r overrideRule) string {
	if _, ok := s.group(r.GroupID); ok {
		return r.GroupID
	}
	return ""
}

// ruleOn is whether a rule is switched on: its own switch and its group's. The master switch is
// left to the caller, which often reports it apart.
func (s overridesState) ruleOn(r overrideRule) bool {
	if !r.Enabled {
		return false
	}
	g, ok := s.group(r.GroupID)
	return !ok || g.Enabled
}

// ruleApplies is whether a rule takes part in matching: the master switch, its own switch and
// its group's are all on.
func (s overridesState) ruleApplies(r overrideRule) bool {
	return s.MasterEnabled && s.ruleOn(r)
}

// activeRules is the rules that are switched on (ruleOn), in precedence order.
func (s overridesState) activeRules() []overrideRule {
	var out []overrideRule
	for _, r := range s.Rules {
		if s.ruleOn(r) {
			out = append(out, r)
		}
	}
	return out
}

// groupRuleCount is how many rules are in a group.
func (s overridesState) groupRuleCount(id string) int {
	n := 0
	for _, r := range s.Rules {
		if s.groupOf(r) == id {
			n++
		}
	}
	return n
}

// arming is what the transport for one app on one device last reported, idle when it reported
// nothing.
func (s overridesState) arming(deviceID, pkg string) armingState {
	for _, a := range s.Armings {
		if a.Target.DeviceID == deviceID && a.Target.Package == pkg {
			return a.State.normalized()
		}
	}
	return idleArming
}

// decodeEach decodes a JSON array element by element, skipping the ones that don't decode, so
// one bad record can't cost the rest. Anything that isn't an array is empty.
func decodeEach[T any](raw json.RawMessage) []T {
	var elements []json.RawMessage
	if len(raw) == 0 || json.Unmarshal(raw, &elements) != nil {
		return nil
	}
	out := make([]T, 0, len(elements))
	for _, element := range elements {
		var value T
		if json.Unmarshal(element, &value) == nil {
			out = append(out, value)
		}
	}
	return out
}

func stringOr(s *string, fallback string) string {
	if s == nil {
		return fallback
	}
	return *s
}

// emptyIfNil makes a nil slice encode as [] and not null, as the app's arrays and sets do.
func emptyIfNil[T any](s []T) []T {
	if s == nil {
		return []T{}
	}
	return s
}

func containsString(list []string, s string) bool {
	for _, item := range list {
		if item == s {
			return true
		}
	}
	return false
}

// transport is the capture transport a rule runs on (InterceptTransportID). jacad captures
// with the two agents and with Jaca's proxy; companion metadata exists so every sentence keeps
// the arm the app has. An unknown value reads as the proxy.
type transport string

const (
	transportAndroidAgent      transport = "androidAgent"
	transportIOSSimulatorAgent transport = "iosSimulatorAgent"
	transportMITMProxy         transport = "mitmProxy"
	transportCompanionMetadata transport = "companionMetadata"
)

// transportFor is HTTPDebuggingSources.transport: the interception point of a capture source on
// a platform. The device proxy and This Mac's Chrome go through Jaca's proxy, and the companion
// app sends flow metadata. The agent, or no source chosen yet, is the agent transport of the
// platform, and the proxy for a platform with no agent (a physical iOS device).
func transportFor(platform, sourceID string) transport {
	switch sourceID {
	case sourceMITM, sourceBrowser:
		return transportMITMProxy
	case sourceCompanion:
		return transportCompanionMetadata
	}
	switch platform {
	case "android":
		return transportAndroidAgent
	case "iosSimulator":
		return transportIOSSimulatorAgent
	}
	return transportMITMProxy
}

// label is InterceptTransportID.label, the short name the skip messages use.
func (t transport) label() string {
	switch t {
	case transportAndroidAgent:
		return "in-process agent"
	case transportIOSSimulatorAgent:
		return "iOS Simulator agent"
	case transportCompanionMetadata:
		return "companion flow metadata"
	}
	return "HTTPS decryption"
}

// The copy below is InterceptTransportCopy.swift, word for word: each sentence is only true for
// one interception point, so it is keyed by transport.

// routingScopeHelp says what is routed and what removes the routing.
func (t transport) routingScopeHelp() string {
	switch t {
	case transportAndroidAgent:
		return "Only these hosts leave the device's own network. Everything else is untouched. " +
			"The adb reverse tunnel is removed when this tab stops, and the agent disarms " +
			"itself if Jaca goes away."
	case transportIOSSimulatorAgent:
		return "Only these hosts are diverted to Jaca. Everything else the app requests goes " +
			"straight out, untouched. The agent disarms itself if Jaca goes away."
	case transportCompanionMetadata:
		return "The companion app reports flow metadata only — there is nothing here to divert."
	}
	return "While this tab is capturing, the device sends everything through Jaca's proxy."
}

// portLabel says how the device reaches the override server.
func (t transport) portLabel(port int) string {
	switch t {
	case transportAndroidAgent:
		return fmt.Sprintf("via adb reverse :%d", port)
	case transportCompanionMetadata:
		return fmt.Sprintf("port %d", port)
	}
	return fmt.Sprintf("127.0.0.1:%d", port)
}

// originExplainer is the caution under "Send and override". "" on the Simulator, where the Mac
// is the app's network.
func (t transport) originExplainer() string {
	switch t {
	case transportIOSSimulatorAgent, transportCompanionMetadata:
		return ""
	}
	return "Jaca fetches this URL from your Mac, not from the device. Origins reachable " +
		"only from the device won't work."
}

// hostsNotice is the editor's notice when a pattern doesn't name a host.
func (t transport) hostsNotice() string {
	switch t {
	case transportAndroidAgent:
		return "This pattern doesn't name a host. Tell Jaca which hosts to route through your " +
			"Mac — only these leave the device's own network."
	case transportIOSSimulatorAgent:
		return "This pattern doesn't name a host. Tell Jaca which hosts to divert — only these " +
			"are answered by Jaca; everything else the app requests is untouched."
	}
	return "This pattern doesn't name a host. Tell Jaca which hosts this rule applies to."
}

// captureDetail is the capture chooser's line for the transport, which names what it can't see.
func (t transport) captureDetail() string {
	switch t {
	case transportAndroidAgent:
		return "Inspect one debuggable Android app in-process — no proxy or CA, with call stacks."
	case transportIOSSimulatorAgent:
		return "Inspect one Simulator app in-process — no proxy or CA. URLSession only: " +
			"WKWebView, background sessions and raw sockets aren't seen."
	case transportCompanionMetadata:
		return "Receive per-app traffic from the Jaca mobile agent over the network."
	}
	return "Decrypt HTTPS device-wide through a proxy the device is set to trust."
}

// agentChooserDetail is the chooser row that covers both agent transports, shown before the
// platform is known.
const agentChooserDetail = "Inspect one app in-process — no proxy or CA. Android: call stacks included. " +
	"iOS Simulator: URLSession only."

// stackLabel is the name of an agent-reported HTTP stack. Only the Android agent reports one.
func stackLabel(httpStack string) string {
	switch httpStack {
	case "urlconnection":
		return "HttpURLConnection"
	}
	return httpStack
}
