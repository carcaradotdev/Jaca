package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

// These port the Swift tests that freeze the override logic: OverrideMatchingTests,
// OverrideCompilerTests, OverrideClampTests, RoutedHostsSyncTests, OverrideRowGateTests and the
// seeding cases of OverrideAuthoringTests.

func ovRule(pattern string, change func(r *overrideRule)) overrideRule {
	r := newOverrideRule()
	r.Matcher.Pattern = pattern
	r.RoutedHosts = derivedRoutedHosts(r.Matcher)
	if change != nil {
		change(&r)
	}
	return r
}

// TestGlobMatching is OverrideMatchingTests' table: the matcher semantics the editor's hint
// text promises.
func TestGlobMatching(t *testing.T) {
	cases := []struct {
		name, pattern, url string
		want               bool
	}{
		{"anchored: a longer URL", "https://a.com/v1", "https://a.com/v1/users", false},
		{"anchored: the same URL", "https://a.com/v1", "https://a.com/v1", true},
		{"anchored: globstar tail", "https://a.com/v1/**", "https://a.com/v1/users", true},
		{"star is one segment", "https://a.com/v1/*/state", "https://a.com/v1/abc/state", true},
		{"star doesn't cross a slash", "https://a.com/v1/*/state", "https://a.com/v1/abc/def/state", false},
		{"globstar crosses slashes", "https://a.com/**/state", "https://a.com/v1/abc/def/state", true},
		{"globstar tail, deep", "https://a.com/**", "https://a.com/a/b/c/d", true},
		{"star falls back to an earlier globstar", "**/api/*", "https://x.com/api/v2/api/thing", true},
		{"star falls back, literal after", "https://a.com/**/v1/*x", "https://a.com/z/v1/q/v1/abx", true},
		{"backtracking keeps star within a segment", "https://a.com/*", "https://a.com/one/two", false},
		{"backtracking finds no match", "https://a.com/**/v1/*x", "https://a.com/z/v1/q/ab/x", false},
		{"globstar matches empty", "https://a.com/v1**", "https://a.com/v1", true},
		{"omitted scheme matches https", "a.com/v1", "https://a.com/v1", true},
		{"omitted scheme matches http", "a.com/v1", "http://a.com/v1", true},
		{"explicit scheme matches", "https://a.com/v1", "https://a.com/v1", true},
		{"explicit scheme is required", "https://a.com/v1", "http://a.com/v1", false},
		{"host ignores case", "https://API.example.com/v1", "https://api.EXAMPLE.com/v1", true},
		{"path keeps case", "https://a.com/Users", "https://a.com/users", false},
		{"port ignored when the pattern names none", "https://a.com/v1", "https://a.com:8443/v1", true},
		{"port matches", "https://a.com:8443/v1", "https://a.com:8443/v1", true},
		{"port differs", "https://a.com:9999/v1", "https://a.com:8443/v1", false},
		{"query ignored without a question mark", "https://a.com/v1", "https://a.com/v1?locale=en&x=1", true},
		{"query requirement, extra parameter", "https://a.com/v1?locale=en", "https://a.com/v1?locale=en&extra=1", true},
		{"query requirement, any order", "https://a.com/v1?locale=en", "https://a.com/v1?extra=1&locale=en", true},
		{"query requirement, other value", "https://a.com/v1?locale=en", "https://a.com/v1?locale=fr", false},
		{"query requirement, missing", "https://a.com/v1?locale=en", "https://a.com/v1", false},
		{"query value wildcard", "https://a.com/v1?token=*", "https://a.com/v1?token=abc123", true},
		{"query value partial wildcard", "https://a.com/v1?token=abc*", "https://a.com/v1?token=abc123", true},
		{"query value partial wildcard, no match", "https://a.com/v1?token=x*", "https://a.com/v1?token=abc123", false},
		{"fragment is never matched", "https://a.com/v1", "https://a.com/v1#section", true},
		{"encoded pattern, encoded URL", "https://a.com/a%20b", "https://a.com/a%20b", true},
		{"decoded pattern, encoded URL", "https://a.com/a b", "https://a.com/a%20b", true},
		{"companion metadata row", "**", "api.example.com:443", false},
	}
	for _, c := range cases {
		if got := ruleMatches(ovRule(c.pattern, nil), c.url, "GET"); got != c.want {
			t.Errorf("%s: %q vs %q = %v, want %v", c.name, c.pattern, c.url, got, c.want)
		}
	}
}

// TestGlobAdversarialPattern checks the failed-state memo: without it this pattern backtracks
// for longer than a test may run.
func TestGlobAdversarialPattern(t *testing.T) {
	pattern := "https://a.com/" + strings.Repeat("**a", 12) + "b"
	url := "https://a.com/" + strings.Repeat("a", 300)
	done := make(chan bool, 1)
	go func() { done <- ruleMatches(ovRule(pattern, nil), url, "GET") }()
	select {
	case got := <-done:
		if got {
			t.Error("matched a subject with no b")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("the matcher didn't finish")
	}
}

func TestURLFacts(t *testing.T) {
	f, ok := urlFactsOf("https://API.Example.com/v1/Users?a=1&a=2&b=x")
	if !ok {
		t.Fatal("a URL didn't parse")
	}
	want := urlFacts{Scheme: "https", Host: "api.example.com", Path: "/v1/Users",
		Normalized: "https://api.example.com/v1/Users", Query: map[string][]string{"a": {"1", "2"}, "b": {"x"}}}
	if !reflect.DeepEqual(f, want) {
		t.Errorf("facts = %+v, want %+v", f, want)
	}
	if f, _ := urlFactsOf("https://example.com"); f.Path != "/" {
		t.Errorf("an empty path = %q, want /", f.Path)
	}
	if f, _ := urlFactsOf("http://a.com:8080/x%20y?q=a+b%26c"); f.Port != "8080" || f.Path != "/x y" ||
		f.Normalized != "http://a.com:8080/x y" || !reflect.DeepEqual(f.Query["q"], []string{"a+b&c"}) {
		t.Errorf("port, decoded path and query = %+v", f)
	}
	if f, _ := urlFactsOf("https://[::1]:8080/x"); f.Host != "[::1]" || f.Port != "8080" || f.Normalized != "https://[::1]:8080/x" {
		t.Errorf("IPv6 host = %+v", f)
	}
	for _, notHTTP := range []string{"api.example.com:443", "", "not a url", "ftp://a.com/x", "a.com/v1"} {
		if _, ok := urlFactsOf(notHTTP); ok {
			t.Errorf("%q parsed as an HTTP URL", notHTTP)
		}
	}
}

func TestMethodFilter(t *testing.T) {
	cases := []struct {
		name    string
		methods []string
		method  string
		want    bool
	}{
		{"no methods is any method", nil, "POST", true},
		{"a listed method", []string{"GET"}, "GET", true},
		{"an unlisted method", []string{"GET"}, "POST", false},
		{"the request's method in any case", []string{"POST"}, "post", true},
	}
	for _, c := range cases {
		r := ovRule("https://a.com/v1", func(r *overrideRule) { r.Matcher.Methods = c.methods })
		if got := ruleMatches(r, "https://a.com/v1", c.method); got != c.want {
			t.Errorf("%s: %v, want %v", c.name, got, c.want)
		}
	}
}

func TestRegexMatching(t *testing.T) {
	regex := func(pattern string) overrideRule {
		return ovRule(pattern, func(r *overrideRule) { r.Matcher.Kind = "regex" })
	}
	cases := []struct {
		name, pattern, url string
		want               bool
	}{
		{"anchored to the whole URL", ".*/product-state", "https://a.com/v1/product-state", true},
		{"a partial pattern", "/product-state", "https://a.com/v1/product-state", false},
		{"case-insensitive", "HTTPS://A\\.COM/V1", "https://a.com/v1", true},
		{"the query is not matched", "https://a\\.com/v1", "https://a.com/v1?x=1", true},
		{"already anchored", "^https://a\\.com/.*$", "https://a.com/v1", true},
	}
	for _, c := range cases {
		if got := ruleMatches(regex(c.pattern), c.url, "GET"); got != c.want {
			t.Errorf("%s: %q vs %q = %v, want %v", c.name, c.pattern, c.url, got, c.want)
		}
	}

	invalid := regex("([")
	set := compileRules([]overrideRule{invalid}, true)
	if len(set.rules) != 0 || set.diagnostic(invalid.ID) != "This regular expression isn't valid." {
		t.Errorf("an invalid regex compiled: %d rules, diagnostic %q", len(set.rules), set.diagnostic(invalid.ID))
	}
	if ruleMatches(invalid, "https://a.com/v1", "GET") {
		t.Error("an invalid regex matched")
	}
}

func TestPatternError(t *testing.T) {
	cases := []struct {
		name    string
		matcher ruleMatcher
		want    string // "error" for any non-empty text
	}{
		{"an empty pattern is not an error", ruleMatcher{Kind: "glob"}, ""},
		{"an empty regex is not an error", ruleMatcher{Kind: "regex"}, ""},
		{"a glob", ruleMatcher{Pattern: "https://a.com/**", Kind: "glob"}, ""},
		{"a blank glob", ruleMatcher{Pattern: "  ", Kind: "glob"}, "This pattern isn't valid."},
		{"a regex", ruleMatcher{Pattern: ".*/users/\\d+", Kind: "regex"}, ""},
		{"a broken regex", ruleMatcher{Pattern: "([", Kind: "regex"}, "error"},
		{"a lookahead, which RE2 lacks", ruleMatcher{Pattern: "https://a.com/(?!v1).*", Kind: "regex"}, "error"},
	}
	for _, c := range cases {
		got := patternError(c.matcher)
		if c.want == "error" {
			if got == "" {
				t.Errorf("%s: no error", c.name)
			}
		} else if got != c.want {
			t.Errorf("%s: %q, want %q", c.name, got, c.want)
		}
	}
	// Go's error names the construct, so the user can tell why the app accepts it.
	if got := patternError(ruleMatcher{Pattern: "a(?=b)", Kind: "regex"}); !strings.Contains(got, "(?=") {
		t.Errorf("the lookahead error is %q", got)
	}
	for pattern, want := range map[string]bool{"a(?=b)": true, `(a)\1`: true, "a++": true, "([": false, "a.*": false} {
		if got := regexMayNeedICU(pattern); got != want {
			t.Errorf("regexMayNeedICU(%q) = %v, want %v", pattern, got, want)
		}
	}
}

func TestDerivedRoutedHosts(t *testing.T) {
	cases := []struct {
		name    string
		matcher ruleMatcher
		want    []string
	}{
		{"a literal host", ruleMatcher{Pattern: "https://api.teya.xyz/lending/**"}, []string{"api.teya.xyz"}},
		{"a literal host without a scheme", ruleMatcher{Pattern: "api.teya.xyz/lending/**"}, []string{"api.teya.xyz"}},
		{"a host with a port, in any case", ruleMatcher{Pattern: " https://API.teya.xyz:8443/x "}, []string{"api.teya.xyz"}},
		{"a wildcard for the whole host", ruleMatcher{Pattern: "**/product-state"}, nil},
		{"a wildcard inside the host", ruleMatcher{Pattern: "*.teya.xyz/v1/**"}, nil},
		{"a regex never derives a host", ruleMatcher{Pattern: ".*", Kind: "regex"}, nil},
		{"an empty pattern", ruleMatcher{}, nil},
	}
	for _, c := range cases {
		if got := derivedRoutedHosts(c.matcher); !reflect.DeepEqual(got, c.want) {
			t.Errorf("%s: %v, want %v", c.name, got, c.want)
		}
	}
	if host, ok := literalHost("https://A.com/x"); host != "a.com" || !ok {
		t.Errorf("literalHost = %q, %v", host, ok)
	}
}

func TestGeneralizePattern(t *testing.T) {
	cases := []struct{ name, in, want string }{
		{"a UUID segment", "https://a.com/v1/companies/3F2504E0-4F89-11D3-9A0C-0305E82C3301/state", "https://a.com/v1/companies/*/state"},
		{"a numeric segment", "https://a.com/users/12345/posts", "https://a.com/users/*/posts"},
		{"a UUID without dashes", "https://a.com/x/3f2504e04f8911d39a0c0305e82c3301", "https://a.com/x/*"},
		{"a long token", "https://a.com/x/abc123def456ghi789/y", "https://a.com/x/*/y"},
		{"route segments stay", "https://a.com/lending/v1/product-state", "https://a.com/lending/v1/product-state"},
		{"a long word with no digit stays", "https://a.com/x/internationalisation", "https://a.com/x/internationalisation"},
		{"no path", "https://a.com", "https://a.com"},
		{"no scheme", "a.com/users/12345", "a.com/users/12345"},
	}
	for _, c := range cases {
		if got := generalizePattern(c.in); got != c.want {
			t.Errorf("%s: %q, want %q", c.name, got, c.want)
		}
	}
}

// TestCompilePrecedenceAndScope is OverrideCompilerTests' precedence and scope cases.
func TestCompilePrecedenceAndScope(t *testing.T) {
	named := func(pattern, name string) overrideRule {
		return ovRule(pattern, func(r *overrideRule) { r.Name = name })
	}
	broad, narrow := named("https://a.com/**", "broad"), named("https://a.com/v1/**", "narrow")

	set := compileRules([]overrideRule{broad, narrow}, true)
	if r, ok := set.firstMatch("https://a.com/v1/users", "GET", "", ""); !ok || r.Name != "broad" {
		t.Errorf("list order: first match = %q, %v", r.Name, ok)
	}
	var names []string
	for _, r := range set.allMatches("https://a.com/v1/x", "GET", "", "") {
		names = append(names, r.Name)
	}
	if !reflect.DeepEqual(names, []string{"broad", "narrow"}) {
		t.Errorf("all matches = %v", names)
	}
	set = compileRules([]overrideRule{narrow, broad}, true)
	if r, _ := set.firstMatch("https://a.com/v1/x", "GET", "", ""); r.Name != "narrow" {
		t.Errorf("reordered: first match = %q", r.Name)
	}

	disabled := ovRule("https://a.com/**", func(r *overrideRule) { r.Enabled = false })
	if set := compileRules([]overrideRule{disabled}, true); len(set.rules) != 0 {
		t.Error("a disabled rule was compiled")
	}
	if !ruleMatches(disabled, "https://a.com/x", "GET") {
		t.Error("ruleMatches didn't compile a disabled rule as if enabled")
	}

	scoped := compileRules([]overrideRule{ovRule("https://a.com/**", func(r *overrideRule) { r.Scope.AppIDs = []string{"com.example"} })}, true)
	scopeCases := []struct {
		name          string
		set           ruleSet
		device, appID string
		want          bool
	}{
		{"the scoped app", scoped, "", "com.example", true},
		{"another app", scoped, "", "com.other", false},
		{"an unknown app", scoped, "", "", false},
		{"an empty scope takes anything", compileRules([]overrideRule{broad}, true), "any", "any", true},
	}
	for _, c := range scopeCases {
		if _, got := c.set.firstMatch("https://a.com/x", "GET", c.device, c.appID); got != c.want {
			t.Errorf("%s: matched = %v, want %v", c.name, got, c.want)
		}
	}
	// The app asks matchingRule with no device or app, so a scoped rule isn't reported.
	if _, ok := scoped.matchingRule("https://a.com/x", "GET"); ok {
		t.Error("matchingRule reported a scoped rule")
	}
	// The master switch is the caller's to apply.
	if _, ok := compileRules([]overrideRule{broad}, false).matchingRule("https://a.com/x", "GET"); !ok {
		t.Error("matchingRule applied the master switch")
	}
}

// TestRoutedHosts is OverrideCompilerTests' blast-radius cases.
func TestRoutedHosts(t *testing.T) {
	a := ovRule("https://a.com/**", nil)
	off := ovRule("https://b.com/**", func(r *overrideRule) { r.Enabled = false })
	scoped := ovRule("https://a.com/**", func(r *overrideRule) { r.Scope.AppIDs = []string{"com.example"} })
	wildcard := ovRule("**/product-state", nil)
	explicit := ovRule("**/product-state", func(r *overrideRule) { r.RoutedHosts = []string{"api.example.com"} })
	cases := []struct {
		name   string
		rules  []overrideRule
		master bool
		appID  string
		want   []string
	}{
		{"enabled rules only", []overrideRule{a, off}, true, "", []string{"a.com"}},
		{"master off routes nothing", []overrideRule{a}, false, "", nil},
		{"in scope", []overrideRule{scoped}, true, "com.example", []string{"a.com"}},
		{"out of scope", []overrideRule{scoped}, true, "com.other", nil},
		{"a wildcard host contributes nothing", []overrideRule{wildcard}, true, "", nil},
		{"explicit hosts for a wildcard pattern", []overrideRule{explicit}, true, "", []string{"api.example.com"}},
		{"a host once, sorted", []overrideRule{explicit, a, a}, true, "", []string{"a.com", "api.example.com"}},
	}
	for _, c := range cases {
		if got := compileRules(c.rules, c.master).routedHosts("", c.appID); !reflect.DeepEqual(got, c.want) {
			t.Errorf("%s: %v, want %v", c.name, got, c.want)
		}
	}
}

func TestCompileDiagnostics(t *testing.T) {
	t.Setenv("JACA_OVERRIDES_DIR", t.TempDir())
	blob, err := makeBodyRef(strings.Repeat("x", inlineBodyLimit+1))
	if err != nil {
		t.Fatal(err)
	}
	withBody := func(body bodyRef) overrideRule {
		return ovRule("https://a.com/**", func(r *overrideRule) { r.Action.Respond.Body = body })
	}
	editWith := func(body *bodyRef) overrideRule {
		return ovRule("https://a.com/**", func(r *overrideRule) {
			r.Action = ruleAction{Kind: "editResponse", Edit: responseEdit{Body: body}}
		})
	}
	cases := []struct {
		name     string
		rule     overrideRule
		compiles bool
		want     string
	}{
		{"a rule with nothing wrong", ovRule("https://a.com/**", nil), true, ""},
		{"an empty pattern", ovRule("", nil), false, "This override has no URL pattern."},
		{"a missing body file", withBody(bodyRef{Kind: "file", Path: "/nope/missing.json"}), true, "Override file is missing: /nope/missing.json"},
		{"a missing blob", withBody(bodyRef{Kind: "blob", Filename: "gone.bin"}), true, "This override's saved body is missing."},
		{"a blob that is there", withBody(blob), true, ""},
		{"an inline body", withBody(bodyRef{Kind: "inline", Text: "{}"}), true, ""},
		{"an edit that keeps the origin's body", editWith(nil), true, ""},
		{"an edit with a missing body file", editWith(&bodyRef{Kind: "file", Path: "/nope/missing.json"}), true, "Override file is missing: /nope/missing.json"},
		{"an empty pattern and a missing body", ovRule("", func(r *overrideRule) { r.Action.Respond.Body = bodyRef{Kind: "blob", Filename: "gone.bin"} }),
			false, "This override's saved body is missing."},
	}
	for _, c := range cases {
		set := compileRules([]overrideRule{c.rule}, true)
		if got := len(set.rules) == 1; got != c.compiles {
			t.Errorf("%s: compiled = %v, want %v", c.name, got, c.compiles)
		}
		if got := set.diagnostic(c.rule.ID); got != c.want {
			t.Errorf("%s: diagnostic %q, want %q", c.name, got, c.want)
		}
	}
	if got := compileRules(nil, true).diagnostic("no-such-rule"); got != "" {
		t.Errorf("an unknown rule has the diagnostic %q", got)
	}
}

// TestClamp is OverrideClampTests: every action against the capability sets.
func TestClamp(t *testing.T) {
	respond := ruleAction{Kind: "respond", Respond: defaultRespondSpec()}
	edit := ruleAction{Kind: "editResponse", Edit: responseEdit{HeaderMode: "merge"}}
	mapRemote := ruleAction{Kind: "mapRemote", MapRemote: "https://b.com"}
	cases := []struct {
		name        string
		action      ruleAction
		caps        int
		master      bool
		enabled     bool
		delayMillis int

		wantAction  string
		wantDelay   time.Duration
		wantKind    string
		wantMissing int
		wantMessage string
	}{
		{"master off, no capabilities", respond, 0, false, true, 0, "proceed", 0, "masterOff", 0, "Overrides are paused."},
		{"master off, desktop terminated", respond, capDesktopTerminated, false, true, 0, "proceed", 0, "masterOff", 0, "Overrides are paused."},
		{"a disabled rule", respond, capDesktopTerminated, true, false, 0, "proceed", 0, "noRuleMatched", 0, "No override matched this request."},
		{"respond runs", respond, capDesktopTerminated, true, true, 0, "respond", 0, "", 0, ""},
		{"respond without short-circuit", respond, 0, true, true, 0, "proceed", 0, "transportUnsupported", capShortCircuit,
			"This rule can't run in HTTPS decryption capture."},
		{"edit runs", edit, capDesktopTerminated, true, true, 0, "edit", 0, "", 0, ""},
		{"edit without bodies", edit, capEditResponse | capShortCircuit | capDelay, true, true, 0, "proceed", 0, "transportUnsupported", capBodies,
			"This rule needs response bodies, which HTTPS decryption capture doesn't provide."},
		{"mapRemote, no capabilities", mapRemote, 0, true, true, 0, "proceed", 0, "transportUnsupported", capMapRemote,
			"Redirecting to another origin isn't supported by HTTPS decryption capture."},
		{"mapRemote, desktop terminated", mapRemote, capDesktopTerminated, true, true, 0, "proceed", 0, "transportUnsupported", capMapRemote,
			"Redirecting to another origin isn't supported by HTTPS decryption capture."},
		{"mapRemote, even when declared", mapRemote, capDesktopTerminated | capMapRemote, true, true, 0, "proceed", 0, "transportUnsupported", capMapRemote,
			"Redirecting to another origin isn't supported by HTTPS decryption capture."},
		{"delay applied", respond, capDesktopTerminated, true, true, 250, "respond", 250 * time.Millisecond, "", 0, ""},
		{"delay dropped when unsupported", respond, capShortCircuit, true, true, 250, "respond", 0, "", 0, ""},
		{"negative delay is zero", respond, capDesktopTerminated, true, true, -5, "respond", 0, "", 0, ""},
	}
	for _, c := range cases {
		r := ovRule("https://a.com/**", func(r *overrideRule) {
			r.Action, r.Enabled, r.DelayMillis = c.action, c.enabled, c.delayMillis
		})
		decision, skip := decideRule(&r, transportMITMProxy, c.caps, c.master)
		if decision.Action != c.wantAction || decision.Delay != c.wantDelay {
			t.Errorf("%s: decided %+v, want %s after %v", c.name, decision, c.wantAction, c.wantDelay)
		}
		if (decision.Action != "proceed") != (decision.RuleID == r.ID) {
			t.Errorf("%s: rule id %q", c.name, decision.RuleID)
		}
		if skip.Kind != c.wantKind || skip.Missing != c.wantMissing {
			t.Errorf("%s: skip %+v, want %s missing %d", c.name, skip, c.wantKind, c.wantMissing)
		}
		if got := skipReason(r, transportMITMProxy, c.caps, c.master); got != c.wantMessage {
			t.Errorf("%s: reason %q, want %q", c.name, got, c.wantMessage)
		}
	}

	if decision, skip := decideRule(nil, transportMITMProxy, capDesktopTerminated, true); decision.Action != "proceed" ||
		decision.Delay != 0 || skip.Kind != "noRuleMatched" {
		t.Errorf("no rule: %+v, %+v", decision, skip)
	}
}

func TestSkipMessages(t *testing.T) {
	cases := []struct {
		skip interceptSkip
		want string
	}{
		{interceptSkip{}, ""},
		{interceptSkip{Kind: "masterOff"}, "Overrides are paused."},
		{interceptSkip{Kind: "transportUnsupported", Transport: transportAndroidAgent, Missing: capBodies},
			"This rule needs response bodies, which in-process agent capture doesn't provide."},
		{interceptSkip{Kind: "transportUnsupported", Transport: transportIOSSimulatorAgent, Missing: capBodies},
			"This rule needs response bodies, which iOS Simulator agent capture doesn't provide."},
		{interceptSkip{Kind: "transportUnsupported", Transport: transportMITMProxy, Missing: capMapRemote},
			"Redirecting to another origin isn't supported by HTTPS decryption capture."},
		{interceptSkip{Kind: "transportUnsupported", Transport: transportCompanionMetadata, Missing: capShortCircuit},
			"This rule can't run in companion flow metadata capture."},
		{interceptSkip{Kind: "transportNotArmed", Detail: "adb reverse failed"}, "adb reverse failed"},
		{interceptSkip{Kind: "noRuleMatched"}, "No override matched this request."},
	}
	for _, c := range cases {
		if got := c.skip.message(); got != c.want {
			t.Errorf("%+v: %q, want %q", c.skip, got, c.want)
		}
	}
}

// TestRoutedHostsSync is RoutedHostsSyncTests.
func TestRoutedHostsSync(t *testing.T) {
	api := []string{"api.example.com"}
	typed := routedHostsSync{Hosts: []string{"a.example.com", "b.example.com"}}
	cases := []struct {
		name string
		got  routedHostsSync
		want routedHostsSync
	}{
		{"a pattern that names a host derives it", routedHostsSync{}.afterMatcherChange(api), routedHostsSync{api, true}},
		{"derived hosts go when the pattern stops naming one", routedHostsSync{api, true}.afterMatcherChange(nil), routedHostsSync{}},
		{"typed hosts survive a pattern that names none", typed.afterMatcherChange(nil), typed},
		{"a literal host replaces typed hosts", typed.afterMatcherChange(api), routedHostsSync{api, true}},
		{"typing makes the set the user's", routedHostsAfterUserEdit([]string{"x.com"}), routedHostsSync{[]string{"x.com"}, false}},
		{"opening a rule recognises derived hosts", initialRoutedHosts(api, api), routedHostsSync{api, true}},
		{"opening a rule saved under a wildcard", initialRoutedHosts(api, nil), routedHostsSync{api, false}},
		{"opening a rule with no hosts", initialRoutedHosts(nil, nil), routedHostsSync{}},
		{"opening a rule whose hosts are more than derived", initialRoutedHosts([]string{"api.example.com", "x.com"}, api),
			routedHostsSync{[]string{"api.example.com", "x.com"}, false}},
	}
	for _, c := range cases {
		if !reflect.DeepEqual(c.got, c.want) {
			t.Errorf("%s: %+v, want %+v", c.name, c.got, c.want)
		}
	}

	// Against the real matcher: switching to regex drops the glob's derived host.
	matcher := ruleMatcher{Pattern: "https://api.example.com/v1/*", Kind: "glob"}
	glob := routedHostsSync{}.afterMatcherChange(derivedRoutedHosts(matcher))
	if !reflect.DeepEqual(glob.Hosts, api) {
		t.Errorf("glob hosts = %v", glob.Hosts)
	}
	matcher.Kind = "regex"
	if regex := glob.afterMatcherChange(derivedRoutedHosts(matcher)); len(regex.Hosts) != 0 {
		t.Errorf("regex hosts = %v", regex.Hosts)
	}
}

// TestRowGate is OverrideRowGateTests.
func TestRowGate(t *testing.T) {
	active := armingState{State: "active", Port: 1, Hosts: []string{"a.com"}}
	detached := armingState{State: "detached", AppID: "com.example.App"}
	const url = "https://a.com/v1/users"
	cases := []struct {
		name      string
		transport transport
		arming    armingState
		running   bool
		available bool
		url       string
		httpStack string
		want      string
	}{
		{"iOS row with a stack that isn't okhttp3", transportIOSSimulatorAgent, active, true, true, url, "urlsession", ""},
		{"iOS row with no stack", transportIOSSimulatorAgent, active, true, true, url, "", ""},
		{"iOS detached names the app", transportIOSSimulatorAgent, detached, true, true, url, "",
			"com.example.App is running without the Jaca agent — relaunch it to resume."},
		{"Android row with an unknown stack", transportAndroidAgent, active, true, true, url, "", ""},
		{"Android okhttp3 row", transportAndroidAgent, active, true, true, url, "okhttp3", ""},
		{"Android row from another stack", transportAndroidAgent, active, true, true, url, "urlconnection",
			"This request came from HttpURLConnection, not okhttp3 — Jaca can't divert it."},
		{"companion row", transportCompanionMetadata, active, true, true, url, "urlsession",
			"Overrides apply to in-process agent capture. Companion capture will follow."},
		{"proxy row, urlsession", transportMITMProxy, active, true, true, url, "urlsession", ""},
		{"proxy row, urlconnection", transportMITMProxy, active, true, true, url, "urlconnection", ""},
		{"overrides unavailable", transportMITMProxy, active, true, false, url, "", "Response overrides aren't available."},
		{"flow metadata row", transportCompanionMetadata, active, true, true, "api.example.com:443", "",
			"This row is flow metadata, not an HTTP request."},
		{"stopped capture has no arming reason", transportIOSSimulatorAgent, detached, false, true, url, "", ""},
		{"stopped capture still blocks another stack", transportAndroidAgent, idleArming, false, true, url, "urlconnection",
			"This request came from HttpURLConnection, not okhttp3 — Jaca can't divert it."},
		{"waiting for the app doesn't block authoring", transportIOSSimulatorAgent, armingState{State: "waitingForApp", AppID: "a"}, true, true, url, "", ""},
	}
	for _, c := range cases {
		if got := rowGate(c.transport, c.arming, c.running, c.available, c.url, c.httpStack); got != c.want {
			t.Errorf("%s: %q, want %q", c.name, got, c.want)
		}
		if c.available {
			txn := netTransaction{URL: c.url, HTTPStack: c.httpStack}
			if got := rowGateReason(c.transport, txn, c.running, c.arming); got != c.want {
				t.Errorf("%s (rowGateReason): %q, want %q", c.name, got, c.want)
			}
		}
	}
}

func TestTransportCopy(t *testing.T) {
	ios, android := transportFor("iosSimulator", "agent"), transportFor("android", "agent")
	if ios != transportIOSSimulatorAgent || android != transportAndroidAgent || transportFor("iosDevice", "") != transportMITMProxy {
		t.Errorf("transportFor: %q, %q, %q", ios, android, transportFor("iosDevice", ""))
	}
	// On the Simulator the Mac is the app's network: no origin caution, no tunnel to name.
	if ios.originExplainer() != "" || strings.Contains(strings.ToLower(ios.routingScopeHelp()), "tunnel") ||
		strings.Contains(strings.ToLower(ios.routingScopeHelp()), "adb") {
		t.Error("the Simulator copy names a tunnel or an origin caution")
	}
	if got := ios.portLabel(41234); got != "127.0.0.1:41234" {
		t.Errorf("Simulator port label = %q", got)
	}
	if got := android.portLabel(41234); got != "via adb reverse :41234" {
		t.Errorf("Android port label = %q", got)
	}
	if !strings.Contains(android.routingScopeHelp(), "adb reverse") || android.originExplainer() == "" {
		t.Error("the Android copy doesn't name its tunnel or its origin caution")
	}
	if strings.Contains(ios.captureDetail(), "call stack") || !strings.Contains(ios.captureDetail(), "URLSession") {
		t.Errorf("Simulator capture detail = %q", ios.captureDetail())
	}
	for _, tr := range []transport{transportAndroidAgent, transportIOSSimulatorAgent, transportMITMProxy, transportCompanionMetadata, "newer"} {
		if tr.label() == "" || tr.hostsNotice() == "" || tr.routingScopeHelp() == "" || tr.captureDetail() == "" {
			t.Errorf("%s has an empty sentence", tr)
		}
	}
	for stack, want := range map[string]string{"okhttp3": "okhttp3", "okhttp2": "okhttp2", "urlconnection": "HttpURLConnection", "cronet": "cronet"} {
		if got := stackLabel(stack); got != want {
			t.Errorf("stackLabel(%q) = %q, want %q", stack, got, want)
		}
	}
}

func TestBlockedMessage(t *testing.T) {
	cases := []struct {
		state armingState
		want  string
	}{
		{armingState{}, ""},
		{idleArming, ""},
		{armingState{State: "active", Port: 1}, ""},
		{armingState{State: "waitingForAgent"}, "Arming — waiting for the agent to load in the app."},
		{armingState{State: "agentTooOld"}, "This app has an older Jaca agent — rebuild it and restart capture."},
		{armingState{State: "waitingForApp", AppID: "com.example.App"}, "Open com.example.App to resume capturing."},
		{armingState{State: "detached", AppID: "com.example.App"}, "com.example.App is running without the Jaca agent — relaunch it to resume."},
		{armingState{State: "failed", Message: "boom"}, "boom"},
	}
	for _, c := range cases {
		if got := c.state.blockedMessage(); got != c.want {
			t.Errorf("%+v: %q, want %q", c.state, got, c.want)
		}
	}
}

// TestSeeding is the seeding cases of OverrideAuthoringTests, plus OverrideSeeding's other
// functions.
func TestSeeding(t *testing.T) {
	t.Setenv("JACA_OVERRIDES_DIR", t.TempDir())
	status := 201
	txn := netTransaction{
		Method: "get", URL: "https://api.teya.xyz/lending/v1/state?locale=en&x=1", Host: "api.teya.xyz", Scheme: "https",
		StatusCode: &status, ResponseContentType: "application/json; charset=utf-8",
		ResponseHeaders: []headerPair{
			{"Content-Type", "application/json"}, {"Content-Length", "17"}, {"content-encoding", "gzip"},
			{"Transfer-Encoding", "chunked"}, {"Connection", "keep-alive"}, {"X-Jaca-Override", "x"}, {"ETag", "abc"},
		},
	}
	rule, err := seedRule(txn, []byte(`{"b":1,"a":{"c":[1,2.50]}}`))
	if err != nil {
		t.Fatal(err)
	}
	if rule.Matcher.Pattern != "https://api.teya.xyz/lending/v1/state" || rule.Matcher.Kind != "glob" ||
		!reflect.DeepEqual(rule.Matcher.Methods, []string{"GET"}) {
		t.Errorf("matcher = %+v", rule.Matcher)
	}
	if rule.Name != "get state" || !rule.Enabled || !isUUID(rule.ID) || rule.CreatedAt == "" {
		t.Errorf("rule = %+v", rule)
	}
	if !reflect.DeepEqual(rule.RoutedHosts, []string{"api.teya.xyz"}) {
		t.Errorf("routed hosts = %v", rule.RoutedHosts)
	}
	wantBody := "{\n  \"a\": {\n    \"c\": [\n      1,\n      2.50\n    ]\n  },\n  \"b\": 1\n}"
	want := respondSpec{StatusCode: 201, Headers: []headerPair{{"Content-Type", "application/json"}, {"ETag", "abc"}},
		Body: bodyRef{Kind: "inline", Text: wantBody}}
	if rule.Action.Kind != "respond" || !reflect.DeepEqual(rule.Action.Respond, want) {
		t.Errorf("action = %+v", rule.Action)
	}

	// A rule seeded from a request matches that request, and the same path with another query.
	set := compileRules([]overrideRule{rule}, true)
	for _, url := range []string{txn.URL, "https://api.teya.xyz/lending/v1/state?locale=fr&extra=9"} {
		if _, ok := set.firstMatch(url, "GET", "", ""); !ok {
			t.Errorf("the seeded rule doesn't match %s", url)
		}
	}

	patterns := []struct{ name, url, wantPattern, wantName string }{
		{"query dropped", "https://a.com/v1/state?locale=en", "https://a.com/v1/state", "GET state"},
		{"no path", "https://a.com", "https://a.com/", "GET a.com"},
		{"port dropped", "http://a.com:8080/v1/", "http://a.com/v1/", "GET v1"},
		{"a flow-metadata row", "api.example.com:443", "api.example.com:443", "GET 443"},
		{"not a URL", "", "", "GET a.com"},
	}
	for _, c := range patterns {
		txn := netTransaction{Method: "GET", URL: c.url, Host: "a.com"}
		if got := seedPattern(txn); got != c.wantPattern {
			t.Errorf("%s: pattern %q, want %q", c.name, got, c.wantPattern)
		}
		if got := seedName(txn); got != c.wantName {
			t.Errorf("%s: name %q, want %q", c.name, got, c.wantName)
		}
	}

	// No status yet, no headers worth keeping, no body.
	bare, err := seedRule(netTransaction{Method: "POST", URL: "https://a.com/x", ResponseHeaders: []headerPair{{"Content-Length", "0"}}}, nil)
	if err != nil || !reflect.DeepEqual(bare.Action.Respond, defaultRespondSpec()) {
		t.Errorf("bare seed = %+v, %v", bare.Action.Respond, err)
	}

	// A body over the inline limit goes to the blob store, and reads back.
	large := strings.Repeat("y", inlineBodyLimit+1)
	blobbed, err := seedRule(netTransaction{Method: "GET", URL: "https://a.com/x", ResponseContentType: "text/plain"}, []byte(large))
	if err != nil {
		t.Fatal(err)
	}
	if body := blobbed.Action.Respond.Body; body.Kind != "blob" {
		t.Errorf("large body = %+v", body)
	} else if text, err := loadBodyText(body); err != nil || text != large {
		t.Errorf("the blob read back %d bytes, %v", len(text), err)
	}
}

func TestSeedWarning(t *testing.T) {
	const streamed = "This is a streamed response. Jaca can't capture streamed bodies, and an override replies with one complete body — the app's stream will end after your payload."
	const truncated = "The captured body hit the 1 MB cap and is truncated. Sending it as-is would return a truncated payload."
	const binary = "Binary responses are captured as text and can't be reproduced byte-for-byte."
	cases := []struct {
		name, contentType string
		bodyLen           int
		want              string
	}{
		{"JSON", "application/json", 10, ""},
		{"no content type", "", 10, ""},
		{"server-sent events", "Text/Event-Stream", 10, streamed},
		{"gRPC", "application/grpc+proto", 10, streamed},
		{"at the capture cap", "application/json", 1024 * 1024, truncated},
		{"under the capture cap", "application/json", 1024*1024 - 1, ""},
		{"an image", "image/png", 10, binary},
		{"a form", "application/x-www-form-urlencoded", 10, ""},
		{"XML", "application/xml", 10, ""},
	}
	for _, c := range cases {
		txn := netTransaction{ResponseContentType: c.contentType}
		if got := seedWarning(txn, make([]byte, c.bodyLen)); got != c.want {
			t.Errorf("%s: %q, want %q", c.name, got, c.want)
		}
	}
}

func TestBlankRule(t *testing.T) {
	blank := blankRule("")
	if blank.Matcher.Pattern != "" || len(blank.RoutedHosts) != 0 || !blank.Enabled || blank.displayName() != "Untitled override" {
		t.Errorf("blank rule = %+v", blank)
	}
	if !reflect.DeepEqual(blank.Action, ruleAction{Kind: "respond", Respond: defaultRespondSpec()}) {
		t.Errorf("blank action = %+v", blank.Action)
	}
	seeded := blankRule("API.example.com")
	if seeded.Matcher.Pattern != "https://API.example.com/" || !reflect.DeepEqual(seeded.RoutedHosts, []string{"api.example.com"}) {
		t.Errorf("seeded blank rule = %+v", seeded)
	}
	if seeded.displayName() != "https://API.example.com/" {
		t.Errorf("display name = %q", seeded.displayName())
	}
	seeded.Name = "Mine"
	if seeded.displayName() != "Mine" {
		t.Errorf("display name = %q", seeded.displayName())
	}
	if a, b := newUUID(), newUUID(); a == b || !isUUID(a) || a != strings.ToUpper(a) || a[14] != '4' {
		t.Errorf("newUUID gave %q then %q", a, b)
	}
}

func TestBodyStore(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("JACA_OVERRIDES_DIR", dir)
	if overridesDir() != dir {
		t.Fatalf("overridesDir = %q", overridesDir())
	}
	atLimit, overLimit := strings.Repeat("é", inlineBodyLimit/2), strings.Repeat("é", inlineBodyLimit/2)+"x"
	cases := []struct {
		name, text, wantKind string
	}{
		{"empty", "", "none"},
		{"short", `{"ok":true}`, "inline"},
		{"at the limit, counted in bytes", atLimit, "inline"},
		{"over the limit", overLimit, "blob"},
	}
	for _, c := range cases {
		ref, err := makeBodyRef(c.text)
		if err != nil || ref.Kind != c.wantKind {
			t.Errorf("%s: %s, %v, want %s", c.name, ref.Kind, err, c.wantKind)
			continue
		}
		if got, err := loadBodyText(ref); err != nil || got != c.text {
			t.Errorf("%s: read back %d bytes, %v", c.name, len(got), err)
		}
		if ref.Kind == "blob" {
			if !strings.HasSuffix(ref.Filename, ".bin") || !isUUID(strings.TrimSuffix(ref.Filename, ".bin")) {
				t.Errorf("%s: blob named %q", c.name, ref.Filename)
			}
			if _, err := os.Stat(filepath.Join(dir, "bodies", ref.Filename)); err != nil {
				t.Errorf("%s: %v", c.name, err)
			}
		}
	}

	file := filepath.Join(dir, "body.json")
	os.WriteFile(file, []byte("from a file"), 0o644)
	os.WriteFile(filepath.Join(dir, "bodies", "binary.bin"), []byte{0xff, 0xfe}, 0o644)
	reads := []struct {
		name    string
		ref     bodyRef
		want    string
		wantErr bool
	}{
		{"the zero value", bodyRef{}, "", false},
		{"a file", bodyRef{Kind: "file", Path: file}, "from a file", false},
		{"a missing file", bodyRef{Kind: "file", Path: filepath.Join(dir, "nope")}, "", true},
		{"a missing blob", bodyRef{Kind: "blob", Filename: "nope.bin"}, "", true},
		{"a blob name that leaves the store", bodyRef{Kind: "blob", Filename: "../body.json"}, "", true},
		{"a blob with no name", bodyRef{Kind: "blob"}, "", true},
		{"a blob that isn't text", bodyRef{Kind: "blob", Filename: "binary.bin"}, "", false},
	}
	for _, c := range reads {
		got, err := loadBodyText(c.ref)
		if got != c.want || (err != nil) != c.wantErr {
			t.Errorf("%s: %q, %v", c.name, got, err)
		}
	}

	// A store that can't be written: the body stays inline, and the error says it wasn't spilled.
	t.Setenv("JACA_OVERRIDES_DIR", filepath.Join(file, "under-a-file"))
	if ref, err := makeBodyRef(overLimit); err == nil || ref.Kind != "inline" || ref.Text != overLimit {
		t.Errorf("unwritable store: %s, %v", ref.Kind, err)
	}
	if ref, err := makeBodyRefBytes(append([]byte{0xff}, overLimit...)); err == nil || ref.Kind != "none" {
		t.Errorf("unwritable store, binary body: %s, %v", ref.Kind, err)
	}
}

// sameJSON compares two JSON texts by value, so key order and spacing don't matter.
func sameJSON(t *testing.T, got []byte, want string) bool {
	t.Helper()
	var a, b any
	if err := json.Unmarshal(got, &a); err != nil {
		t.Fatalf("encoded JSON doesn't parse: %v", err)
	}
	if err := json.Unmarshal([]byte(want), &b); err != nil {
		t.Fatalf("the fixture doesn't parse: %v", err)
	}
	return reflect.DeepEqual(a, b)
}

const (
	wireRule = `{"action":{"kind":"respond","respond":{"body":{"kind":"inline","text":"{\"teapot\":true}"},"headers":[{"name":"Content-Type","value":"application/json"}],"statusCode":418}},"createdAt":"2026-10-06T11:58:00.000Z","delayMillis":250,"divertHosts":["api.example.com"],"enabled":true,"id":"3D5E8A10-7B2C-4F6D-9E1A-2B3C4D5E6F70","matcher":{"kind":"glob","methods":["GET"],"pattern":"https://api.example.com/users/*"},"name":"Stub users","scope":{"appIDs":[],"deviceIDs":[]}}`

	wireEditRule = `{"action":{"editResponse":{"body":{"kind":"file","path":"/tmp/users.json","watch":false},"headerMode":"replace","headers":[{"name":"X-Debug","value":"1"}],"removeHeaders":["Set-Cookie","ETag"],"statusCode":503},"kind":"editResponse"},"createdAt":"2026-10-06T11:58:00.000Z","delayMillis":0,"divertHosts":["b.example.com","a.example.com"],"enabled":false,"id":"0A1B2C3D-0000-4000-8000-00000000000A","matcher":{"kind":"regex","methods":["POST","GET"],"pattern":".*/users/\\d+"},"name":"","scope":{"appIDs":["com.example.app"],"deviceIDs":["emulator-5554"]}}`

	wireEditKeepRule = `{"action":{"editResponse":{"headerMode":"merge","headers":[],"removeHeaders":["Cache-Control"]},"kind":"editResponse"},"createdAt":"2026-10-06T11:58:00Z","delayMillis":0,"divertHosts":[],"enabled":true,"id":"0A1B2C3D-0000-4000-8000-00000000000B","matcher":{"kind":"glob","methods":[],"pattern":"a.com/**"},"name":"Keep","scope":{"appIDs":[],"deviceIDs":[]}}`

	wireFileRule = `{"action":{"kind":"respond","respond":{"body":{"kind":"file","path":"/Users/me/mock.json","watch":true},"headers":[],"statusCode":200}},"createdAt":"2026-10-06T11:58:00.000Z","delayMillis":0,"divertHosts":["a.com"],"enabled":true,"id":"0A1B2C3D-0000-4000-8000-00000000000C","matcher":{"kind":"glob","methods":[],"pattern":"https://a.com/**"},"name":"Map local","scope":{"appIDs":[],"deviceIDs":[]}}`

	wireBlobRule = `{"action":{"kind":"respond","respond":{"body":{"filename":"6F1C2B1E-9A0D-4C55-8E2B-0C1D2E3F4A5B.bin","kind":"blob"},"headers":[{"name":"Content-Type","value":"text/html"}],"statusCode":200}},"createdAt":"2026-10-06T11:58:00.000Z","delayMillis":0,"divertHosts":["a.com"],"enabled":true,"id":"0A1B2C3D-0000-4000-8000-00000000000D","matcher":{"kind":"glob","methods":[],"pattern":"https://a.com/**"},"name":"Big","scope":{"appIDs":[],"deviceIDs":[]}}`

	wireMapRemoteRule = `{"action":{"kind":"mapRemote","mapRemote":"https://staging.example.com"},"createdAt":"2026-10-06T11:58:00.000Z","delayMillis":0,"divertHosts":["a.com"],"enabled":true,"id":"0A1B2C3D-0000-4000-8000-00000000000E","matcher":{"kind":"glob","methods":[],"pattern":"https://a.com/**"},"name":"Remote","scope":{"appIDs":[],"deviceIDs":[]}}`

	wireState = `{"armings":[{"state":{"hosts":["api.example.com"],"port":51234,"state":"active"},"target":{"deviceID":"emulator-5554","package":"com.example.app"}}],"hitCounts":{"3D5E8A10-7B2C-4F6D-9E1A-2B3C4D5E6F70":3},"lastActivity":"12:00:01 · applied Stub users","lastHitAt":{"3D5E8A10-7B2C-4F6D-9E1A-2B3C4D5E6F70":"2026-10-06T12:00:01.480Z"},"masterEnabled":true,"reclaimedTunnelCount":0,"rules":[]}`

	wireTransaction = `{"bodiesEvicted":true,"callStack":["com.example.api.UserRepo.load(UserRepo.kt:42)"],"finishedAt":"2026-10-06T12:00:01.480Z","host":"api.example.com","httpStack":"okhttp3","id":"6F1C2B1E-9A0D-4C55-8E2B-0C1D2E3F4A5B","method":"GET","overriddenByRuleID":"3D5E8A10-7B2C-4F6D-9E1A-2B3C4D5E6F70","requestBytes":0,"requestHeaders":[{"name":"Accept","value":"application/json"}],"responseBytes":17,"responseContentType":"application/json","responseHeaders":[{"name":"Content-Type","value":"application/json"},{"name":"X-Jaca-Override","value":"3D5E8A10-7B2C-4F6D-9E1A-2B3C4D5E6F70"}],"responseReceivedAt":"2026-10-06T12:00:01.470Z","scheme":"https","startedAt":"2026-10-06T12:00:01.250Z","statusCode":418,"url":"https://api.example.com/users/42?expand=1"}`

	wireCaptureState = `{"attachState":{"state":"idle"},"boundPort":0,"caReady":false,"hasRunningSource":true,"hasSelectedMode":true,"interceptCapabilities":15,"interceptWired":true,"isConnecting":false,"isRunning":true,"offeredSourceIDs":["agent"],"proxyNeedsSetup":false,"selectedSourceID":"agent","statusMessage":"agent: waiting for com.example.app to start…","targetPackage":"com.example.app"}`
)

func TestRuleWire(t *testing.T) {
	var rule overrideRule
	if err := json.Unmarshal([]byte(wireRule), &rule); err != nil {
		t.Fatal(err)
	}
	want := overrideRule{
		ID: "3D5E8A10-7B2C-4F6D-9E1A-2B3C4D5E6F70", Name: "Stub users", Enabled: true,
		Matcher: ruleMatcher{Pattern: "https://api.example.com/users/*", Kind: "glob", Methods: []string{"GET"}},
		Scope:   ruleScope{DeviceIDs: []string{}, AppIDs: []string{}},
		Action: ruleAction{Kind: "respond", Respond: respondSpec{StatusCode: 418,
			Headers: []headerPair{{"Content-Type", "application/json"}}, Body: bodyRef{Kind: "inline", Text: `{"teapot":true}`}}},
		DelayMillis: 250, CreatedAt: "2026-10-06T11:58:00.000Z", RoutedHosts: []string{"api.example.com"},
	}
	if !reflect.DeepEqual(rule, want) {
		t.Errorf("decoded %+v\nwant    %+v", rule, want)
	}
	if !ruleMatches(rule, "https://api.example.com/users/42?expand=1", "GET") {
		t.Error("the decoded rule doesn't match its request")
	}

	// Nothing may be lost between overrides.state and overrides.save, including what the pane
	// doesn't show.
	fixtures := map[string]string{
		"respond with an inline body":       wireRule,
		"edit with removeHeaders and scope": wireEditRule,
		"edit that keeps status and body":   wireEditKeepRule,
		"respond with a file body":          wireFileRule,
		"respond with a blob body":          wireBlobRule,
		"mapRemote":                         wireMapRemoteRule,
	}
	for name, fixture := range fixtures {
		var rule overrideRule
		if err := json.Unmarshal([]byte(fixture), &rule); err != nil {
			t.Errorf("%s: %v", name, err)
			continue
		}
		encoded, err := json.Marshal(rule)
		if err != nil || !sameJSON(t, encoded, fixture) {
			t.Errorf("%s: re-encoded as %s (%v)", name, encoded, err)
		}
	}

	// The set order the daemon sent is kept, so a save doesn't reshuffle it.
	var edit overrideRule
	json.Unmarshal([]byte(wireEditRule), &edit)
	if !reflect.DeepEqual(edit.RoutedHosts, []string{"b.example.com", "a.example.com"}) ||
		!reflect.DeepEqual(edit.Action.Edit.RemoveHeaders, []string{"Set-Cookie", "ETag"}) ||
		edit.Action.Edit.StatusCode == nil || *edit.Action.Edit.StatusCode != 503 ||
		*edit.Action.Edit.Body != (bodyRef{Kind: "file", Path: "/tmp/users.json"}) {
		t.Errorf("edit rule = %+v", edit)
	}
}

// TestRuleDecodeDefaults is OverrideMigrationTests' contract: only the id is required.
func TestRuleDecodeDefaults(t *testing.T) {
	const id = `"id":"3d5e8a10-7b2c-4f6d-9e1a-2b3c4d5e6f70"`
	decode := func(t *testing.T, text string) overrideRule {
		t.Helper()
		var rule overrideRule
		if err := json.Unmarshal([]byte(text), &rule); err != nil {
			t.Fatalf("%s: %v", text, err)
		}
		return rule
	}

	bare := decode(t, `{`+id+`}`)
	if bare.ID != "3D5E8A10-7B2C-4F6D-9E1A-2B3C4D5E6F70" || !bare.Enabled || bare.Name != "" || bare.DelayMillis != 0 ||
		bare.Matcher.Kind != "glob" || bare.Matcher.Pattern != "" || len(bare.RoutedHosts) != 0 || bare.CreatedAt == "" {
		t.Errorf("an id alone decoded as %+v", bare)
	}
	if !reflect.DeepEqual(bare.Action, ruleAction{Kind: "respond", Respond: defaultRespondSpec()}) {
		t.Errorf("default action = %+v", bare.Action)
	}
	if encoded, err := json.Marshal(bare); err != nil || !sameJSON(t, encoded, `{"action":{"kind":"respond","respond":{"body":{"kind":"none"},"headers":[{"name":"Content-Type","value":"application/json"}],"statusCode":200}},"createdAt":"`+bare.CreatedAt+`","delayMillis":0,"divertHosts":[],"enabled":true,"id":"3D5E8A10-7B2C-4F6D-9E1A-2B3C4D5E6F70","matcher":{"kind":"glob","methods":[],"pattern":""},"name":"","scope":{"appIDs":[],"deviceIDs":[]}}`) {
		t.Errorf("an id alone encoded as %s (%v)", encoded, err)
	}

	actions := []struct {
		name, action string
		want         ruleAction
	}{
		{"an unknown action kind is respond", `{"kind":"breakpoint","respond":{"statusCode":404}}`,
			ruleAction{Kind: "respond", Respond: respondSpec{StatusCode: 404, Headers: defaultRespondSpec().Headers, Body: bodyRef{Kind: "none"}}}},
		{"no action kind is respond", `{}`, ruleAction{Kind: "respond", Respond: defaultRespondSpec()}},
		{"an unknown body kind is none", `{"kind":"respond","respond":{"body":{"kind":"stream","text":"x"}}}`,
			ruleAction{Kind: "respond", Respond: defaultRespondSpec()}},
		{"a blob with no filename is none", `{"kind":"respond","respond":{"body":{"kind":"blob"}}}`,
			ruleAction{Kind: "respond", Respond: defaultRespondSpec()}},
		{"a file with no path is none", `{"kind":"respond","respond":{"body":{"kind":"file","watch":true}}}`,
			ruleAction{Kind: "respond", Respond: defaultRespondSpec()}},
		{"a file is watched unless it says otherwise", `{"kind":"respond","respond":{"headers":[],"body":{"kind":"file","path":"/x"}}}`,
			ruleAction{Kind: "respond", Respond: respondSpec{StatusCode: 200, Headers: []headerPair{}, Body: bodyRef{Kind: "file", Path: "/x", Watch: true}}}},
		{"an edit with nothing in it", `{"kind":"editResponse"}`, ruleAction{Kind: "editResponse", Edit: responseEdit{HeaderMode: "merge"}}},
		{"an edit with null fields", `{"kind":"editResponse","editResponse":{"statusCode":null,"body":null,"headers":null}}`,
			ruleAction{Kind: "editResponse", Edit: responseEdit{HeaderMode: "merge"}}},
		{"mapRemote with no URL", `{"kind":"mapRemote"}`, ruleAction{Kind: "mapRemote"}},
		{"a header missing its value", `{"kind":"respond","respond":{"headers":[{"name":"X-A"}]}}`,
			ruleAction{Kind: "respond", Respond: respondSpec{StatusCode: 200, Headers: []headerPair{{Name: "X-A"}}, Body: bodyRef{Kind: "none"}}}},
	}
	for _, c := range actions {
		if got := decode(t, `{`+id+`,"action":`+c.action+`}`).Action; !reflect.DeepEqual(got, c.want) {
			t.Errorf("%s: %+v, want %+v", c.name, got, c.want)
		}
	}

	// A numeric createdAt is seconds since 1970, the daemon's other accepted form.
	if got := decode(t, `{`+id+`,"createdAt":1791287880.5}`).CreatedAt; got != "2026-10-06T11:58:00.500Z" {
		t.Errorf("numeric createdAt = %q", got)
	}
	if got := decode(t, `{`+id+`,"enabled":false,"name":null,"unknownFutureKey":{"a":1}}`); got.Enabled || got.Name != "" {
		t.Errorf("explicit false and null: %+v", got)
	}

	// What the app's decoder refuses, this refuses, so the pane lists the rules the app lists.
	for name, text := range map[string]string{
		"no id":                  `{"name":"x"}`,
		"an id that is no UUID":  `{"id":"abc"}`,
		"an unknown matcher":     `{` + id + `,"matcher":{"kind":"xpath"}}`,
		"an unknown header mode": `{` + id + `,"action":{"kind":"editResponse","editResponse":{"headerMode":"append"}}}`,
		"a name that is no text": `{` + id + `,"name":7}`,
	} {
		var rule overrideRule
		if json.Unmarshal([]byte(text), &rule) == nil {
			t.Errorf("%s decoded", name)
		}
	}
}

func TestOverridesStateWire(t *testing.T) {
	var state overridesState
	if err := json.Unmarshal([]byte(wireState), &state); err != nil {
		t.Fatal(err)
	}
	const id = "3D5E8A10-7B2C-4F6D-9E1A-2B3C4D5E6F70"
	active := armingState{State: "active", Port: 51234, Hosts: []string{"api.example.com"}}
	if !state.MasterEnabled || len(state.Rules) != 0 || state.HitCounts[id] != 3 || state.LastHitAt[id] != "2026-10-06T12:00:01.480Z" ||
		state.LastActivity != "12:00:01 · applied Stub users" || state.ReclaimedTunnelCount != 0 {
		t.Errorf("state = %+v", state)
	}
	if got := state.arming("emulator-5554", "com.example.app"); !reflect.DeepEqual(got, active) {
		t.Errorf("arming = %+v", got)
	}
	// Keyed by device and app: the same app on another device has nothing armed.
	if got := state.arming("emulator-5556", "com.example.app"); !reflect.DeepEqual(got, idleArming) {
		t.Errorf("arming on another device = %+v", got)
	}
	if got := active.normalized().blockedMessage(); got != "" {
		t.Errorf("active is blocked: %q", got)
	}
	if encoded, err := json.Marshal(state); err != nil || !sameJSON(t, encoded, wireState) {
		t.Errorf("re-encoded as %s (%v)", encoded, err)
	}

	// One rule that doesn't decode is skipped; the others and the rest of the state stay.
	tolerant := `{"rules":[` + wireRule + `,{"name":"no id"},` + wireMapRemoteRule + `],"hitCounts":"broken","armings":[{"target":{"deviceID":"d","package":"p"}},{"target":{"deviceID":"d","package":"p"},"state":{"state":"fromTheFuture"}}]}`
	state = overridesState{}
	if err := json.Unmarshal([]byte(tolerant), &state); err != nil {
		t.Fatal(err)
	}
	if len(state.Rules) != 2 || state.Rules[0].Name != "Stub users" || state.Rules[1].Action.Kind != "mapRemote" {
		t.Errorf("rules = %+v", state.Rules)
	}
	if !state.MasterEnabled || state.HitCounts == nil || len(state.HitCounts) != 0 || state.LastActivity != "" {
		t.Errorf("defaults = %+v", state)
	}
	if len(state.Armings) != 1 || !reflect.DeepEqual(state.arming("d", "p"), idleArming) {
		t.Errorf("armings = %+v", state.Armings)
	}
}

func TestArmingStateWire(t *testing.T) {
	cases := []struct {
		name, wire string
		want       armingState
		encoded    string
	}{
		{"idle", `{"state":"idle"}`, idleArming, `{"state":"idle"}`},
		{"no state", `{}`, idleArming, `{"state":"idle"}`},
		{"a state from a newer build", `{"state":"paused","appID":"a"}`, idleArming, `{"state":"idle"}`},
		{"not an object", `"active"`, idleArming, `{"state":"idle"}`},
		{"waiting for the agent", `{"state":"waitingForAgent"}`, armingState{State: "waitingForAgent"}, `{"state":"waitingForAgent"}`},
		{"agent too old", `{"state":"agentTooOld"}`, armingState{State: "agentTooOld"}, `{"state":"agentTooOld"}`},
		{"waiting for the app", `{"state":"waitingForApp","appID":"com.a"}`, armingState{State: "waitingForApp", AppID: "com.a"},
			`{"state":"waitingForApp","appID":"com.a"}`},
		{"detached", `{"appID":"com.a","state":"detached"}`, armingState{State: "detached", AppID: "com.a"}, `{"state":"detached","appID":"com.a"}`},
		{"active, hosts sorted on the way out", `{"state":"active","port":5,"hosts":["b.com","a.com"]}`,
			armingState{State: "active", Port: 5, Hosts: []string{"b.com", "a.com"}}, `{"state":"active","port":5,"hosts":["a.com","b.com"]}`},
		{"active with nothing else", `{"state":"active"}`, armingState{State: "active"}, `{"state":"active","port":0,"hosts":[]}`},
		{"failed", `{"state":"failed","message":"adb reverse failed"}`, armingState{State: "failed", Message: "adb reverse failed"},
			`{"state":"failed","message":"adb reverse failed"}`},
	}
	for _, c := range cases {
		var got armingState
		if err := json.Unmarshal([]byte(c.wire), &got); err != nil || !reflect.DeepEqual(got, c.want) {
			t.Errorf("%s: decoded %+v (%v), want %+v", c.name, got, err, c.want)
		}
		if encoded, err := json.Marshal(got); err != nil || !sameJSON(t, encoded, c.encoded) {
			t.Errorf("%s: encoded %s (%v), want %s", c.name, encoded, err, c.encoded)
		}
	}
}

func TestTransactionWire(t *testing.T) {
	var txn netTransaction
	if err := json.Unmarshal([]byte(wireTransaction), &txn); err != nil {
		t.Fatal(err)
	}
	if txn.ID != "6F1C2B1E-9A0D-4C55-8E2B-0C1D2E3F4A5B" || txn.Method != "GET" || txn.Host != "api.example.com" || txn.Scheme != "https" ||
		txn.URL != "https://api.example.com/users/42?expand=1" || !txn.BodiesEvicted || txn.HTTPStack != "okhttp3" ||
		txn.OverriddenByRuleID != "3D5E8A10-7B2C-4F6D-9E1A-2B3C4D5E6F70" || txn.ResponseBytes != 17 || txn.Error != "" ||
		txn.ResponseContentType != "application/json" || !reflect.DeepEqual(txn.CallStack, []string{"com.example.api.UserRepo.load(UserRepo.kt:42)"}) {
		t.Errorf("transaction = %+v", txn)
	}
	if got := txn.statusText(); got != "418" {
		t.Errorf("status text = %q", got)
	}
	if got := txn.path(); got != "/users/42" {
		t.Errorf("path = %q", got)
	}
	if d, ok := txn.duration(); !ok || d != 230*time.Millisecond || formatNetDuration(d, ok) != "230 ms" {
		t.Errorf("duration = %v, %v", d, ok)
	}
	if d, ok := txn.ttfb(); !ok || d != 220*time.Millisecond {
		t.Errorf("ttfb = %v, %v", d, ok)
	}
	if got := txn.displayResponseHeaders(); !reflect.DeepEqual(got, []headerPair{{"Content-Type", "application/json"}}) {
		t.Errorf("display response headers = %v", got)
	}
	if got := txn.displayRequestHeaders(); !reflect.DeepEqual(got, []headerPair{{"Accept", "application/json"}}) {
		t.Errorf("display request headers = %v", got)
	}
	if got := txn.requestContentType(); got != "" {
		t.Errorf("request content type = %q", got)
	}
	if got := rowGateReason(transportAndroidAgent, txn, true, idleArming); got != "" {
		t.Errorf("row gate = %q", got)
	}

	// In flight: only what a request has when it starts.
	var started netTransaction
	inFlight := `{"host":"a.com","id":"6F1C2B1E-9A0D-4C55-8E2B-0C1D2E3F4A5B","method":"POST","requestBytes":2,"requestHeaders":[{"name":"content-TYPE","value":"text/plain"},{"name":"x-jaca-original-url","value":"https://a.com"}],"responseBytes":0,"scheme":"https","startedAt":"2026-10-06T12:00:01.250Z","url":"https://a.com"}`
	if err := json.Unmarshal([]byte(inFlight), &started); err != nil {
		t.Fatal(err)
	}
	if got := started.statusText(); got != "…" {
		t.Errorf("in-flight status text = %q", got)
	}
	if _, ok := started.duration(); ok {
		t.Error("an unfinished request has a duration")
	}
	if _, ok := started.ttfb(); ok {
		t.Error("an unanswered request has a time to first byte")
	}
	if got := started.path(); got != "https://a.com" {
		t.Errorf("path of a URL without one = %q", got)
	}
	if got := started.requestContentType(); got != "text/plain" {
		t.Errorf("request content type = %q", got)
	}
	if got := started.displayRequestHeaders(); len(got) != 1 {
		t.Errorf("display request headers = %v", got)
	}
	started.Error = "connection reset"
	if got := started.statusText(); got != "ERR" {
		t.Errorf("failed status text = %q", got)
	}
	if got := (netTransaction{URL: "api.example.com:443", Scheme: "https"}).path(); got != "443" {
		t.Errorf("path of a flow-metadata row = %q", got)
	}
}

func TestCaptureStateWire(t *testing.T) {
	var state netState
	if err := json.Unmarshal([]byte(wireCaptureState), &state); err != nil {
		t.Fatal(err)
	}
	want := netState{IsRunning: true, StatusMessage: "agent: waiting for com.example.app to start…", SelectedSourceID: "agent",
		HasSelectedMode: true, TargetPackage: "com.example.app", AttachState: idleArming, InterceptWired: true,
		InterceptCapabilities: capDesktopTerminated, HasRunningSource: true, OfferedSourceIDs: []string{"agent"}}
	if !reflect.DeepEqual(state, want) {
		t.Errorf("state = %+v\nwant    %+v", state, want)
	}
	// Missing keys are the defaults, and an attach state this client can't read is idle.
	state = netState{}
	if err := json.Unmarshal([]byte(`{"attachState":{"state":"detached","appID":"com.a"}}`), &state); err != nil ||
		!reflect.DeepEqual(state.AttachState, armingState{State: "detached", AppID: "com.a"}) || state.IsRunning {
		t.Errorf("partial state = %+v, %v", state, err)
	}
	state = netState{}
	if err := json.Unmarshal([]byte(`{"attachState":7,"isRunning":true}`), &state); err != nil ||
		!reflect.DeepEqual(state.AttachState, idleArming) || !state.IsRunning {
		t.Errorf("unreadable attach state = %+v, %v", state, err)
	}
}

func TestNetFormatting(t *testing.T) {
	sizes := []struct {
		bytes int
		want  string
	}{
		{0, "—"}, {-1, "—"}, {1, "1 B"}, {1023, "1023 B"}, {1024, "1.0 KB"}, {1536, "1.5 KB"},
		{1024*1024 - 1, "1024.0 KB"}, {1024 * 1024, "1.0 MB"}, {5 * 1024 * 1024 / 2, "2.5 MB"},
	}
	for _, c := range sizes {
		if got := formatNetSize(c.bytes); got != c.want {
			t.Errorf("formatNetSize(%d) = %q, want %q", c.bytes, got, c.want)
		}
	}
	durations := []struct {
		d    time.Duration
		ok   bool
		want string
	}{
		{0, false, "—"}, {0, true, "0 ms"}, {230 * time.Millisecond, true, "230 ms"}, {999900 * time.Microsecond, true, "999 ms"},
		{time.Second, true, "1.00 s"}, {1234 * time.Millisecond, true, "1.23 s"}, {75 * time.Second, true, "75.00 s"},
	}
	for _, c := range durations {
		if got := formatNetDuration(c.d, c.ok); got != c.want {
			t.Errorf("formatNetDuration(%v, %v) = %q, want %q", c.d, c.ok, got, c.want)
		}
	}
	bodies := []struct {
		name, body, contentType, want string
	}{
		{"empty", "", "application/json", ""},
		{"JSON, keys sorted", `{"b":1,"a":[true,null,"x/y"]}`, "application/JSON; charset=utf-8",
			"{\n  \"a\": [\n    true,\n    null,\n    \"x/y\"\n  ],\n  \"b\": 1\n}"},
		{"JSON numbers keep their digits", `[1.10,12345678901234567890]`, "application/json", "[\n  1.10,\n  12345678901234567890\n]"},
		{"JSON that doesn't parse", `{"a":`, "application/json", `{"a":`},
		{"JSON followed by more", `{"a":1} x`, "application/json", `{"a":1} x`},
		{"a top-level fragment is left alone", `"text"`, "application/json", `"text"`},
		{"JSON under another type", `{"b":1,"a":2}`, "text/plain", `{"b":1,"a":2}`},
		{"text", "héllo <b>", "text/html", "héllo <b>"},
		{"binary", "\xff\xfe\x00", "image/png", "<3 B binary data>"},
		{"binary under a JSON type", strings.Repeat("\xff", 2048), "application/json", "<2.0 KB binary data>"},
	}
	for _, c := range bodies {
		if got := netBodyText([]byte(c.body), c.contentType); got != c.want {
			t.Errorf("%s: %q, want %q", c.name, got, c.want)
		}
	}
}

const (
	groupA = "A0000000-0000-4000-8000-00000000000A"
	groupB = "B0000000-0000-4000-8000-00000000000B"
)

// A daemon with groups sends them in display order, and a rule names its group by groupID.
func TestOverridesStateGroupsWire(t *testing.T) {
	grouped := strings.Replace(wireRule, `"enabled":true,`, `"enabled":true,"groupID":"`+strings.ToLower(groupA)+`",`, 1)
	text := `{"masterEnabled":true,"rules":[` + grouped + `,` + wireMapRemoteRule + `],"groups":[` +
		`{"id":"` + groupA + `","name":"Checkout","enabled":false,"createdAt":"2026-10-06T11:00:00.000Z"},` +
		`{"id":"` + groupB + `"},{"name":"no id"},{"id":"` + groupA + `","name":"twice"}]}`
	var state overridesState
	if err := json.Unmarshal([]byte(text), &state); err != nil {
		t.Fatal(err)
	}
	want := []overrideGroup{
		{ID: groupA, Name: "Checkout", Enabled: false, CreatedAt: "2026-10-06T11:00:00.000Z"},
		{ID: groupB, Name: "", Enabled: true, CreatedAt: state.Groups[1].CreatedAt},
	}
	if !state.HasGroups || !reflect.DeepEqual(state.Groups, want) {
		t.Errorf("groups = %+v (has %v), want %+v", state.Groups, state.HasGroups, want)
	}
	if len(state.Rules) != 2 || state.Rules[0].GroupID != groupA || state.Rules[1].GroupID != "" {
		t.Fatalf("rules = %+v", state.Rules)
	}
	if state.groupOf(state.Rules[0]) != groupA || state.groupRuleCount(groupA) != 1 || state.groupRuleCount(groupB) != 0 {
		t.Errorf("groupOf = %q, counts %d %d", state.groupOf(state.Rules[0]), state.groupRuleCount(groupA), state.groupRuleCount(groupB))
	}
	if g := state.Groups[1]; g.displayName() != "Untitled group" {
		t.Errorf("an unnamed group is called %q", g.displayName())
	}
	encoded, _ := json.Marshal(state)
	var again overridesState
	if err := json.Unmarshal(encoded, &again); err != nil || !again.HasGroups || !reflect.DeepEqual(again.Groups, want) {
		t.Errorf("re-decoded groups %+v from %s (%v)", again.Groups, encoded, err)
	}

	// A daemon from before groups: no groups key, and the state encodes without one.
	var old overridesState
	if err := json.Unmarshal([]byte(wireState), &old); err != nil {
		t.Fatal(err)
	}
	if old.HasGroups || len(old.Groups) != 0 {
		t.Errorf("an old state has groups: %+v", old.Groups)
	}
	if encoded, _ := json.Marshal(old); strings.Contains(string(encoded), "groups") {
		t.Errorf("an old state encoded with groups: %s", encoded)
	}
	// An empty list is still a daemon that has groups.
	var none overridesState
	if json.Unmarshal([]byte(`{"rules":[],"groups":[]}`), &none) != nil || !none.HasGroups {
		t.Errorf("an empty groups list reads as no groups: %+v", none)
	}
	if encoded, _ := json.Marshal(none); !strings.Contains(string(encoded), `"groups":[]`) {
		t.Errorf("an empty groups list encoded as %s", encoded)
	}
}

// groupID goes back to the daemon as it came, so saving a rule from the editor keeps it in its
// group; a rule in no group sends no groupID.
func TestRuleGroupIDRoundTrip(t *testing.T) {
	grouped := strings.Replace(wireRule, `"enabled":true,`, `"enabled":true,"groupID":"`+groupA+`",`, 1)
	var rule overrideRule
	if err := json.Unmarshal([]byte(grouped), &rule); err != nil {
		t.Fatal(err)
	}
	if rule.GroupID != groupA {
		t.Fatalf("groupID = %q", rule.GroupID)
	}
	if encoded, err := json.Marshal(rule); err != nil || !sameJSON(t, encoded, grouped) {
		t.Errorf("re-encoded as %s (%v)", encoded, err)
	}
	// Through the editor: open, save, and the group is still there.
	v := testNetViewer(t)
	v.openEditor(rule, false, "")
	built, err := v.ovui.draft.build()
	if err != nil || built.GroupID != groupA {
		t.Errorf("the editor built groupID %q (%v)", built.GroupID, err)
	}
	for name, text := range map[string]string{
		"absent":  wireRule,
		"null":    strings.Replace(wireRule, `"enabled":true,`, `"enabled":true,"groupID":null,`, 1),
		"no UUID": strings.Replace(wireRule, `"enabled":true,`, `"enabled":true,"groupID":"checkout",`, 1),
	} {
		var r overrideRule
		if err := json.Unmarshal([]byte(text), &r); err != nil || r.GroupID != "" {
			t.Errorf("%s: groupID %q (%v)", name, r.GroupID, err)
			continue
		}
		if encoded, _ := json.Marshal(r); strings.Contains(string(encoded), "groupID") {
			t.Errorf("%s: encoded with a groupID: %s", name, encoded)
		}
	}
}

// A rule applies only when the master switch, its own switch and its group's are all on. A
// groupID naming no listed group is no group.
func TestRuleEffectiveEnabled(t *testing.T) {
	in := func(group string, enabled bool) overrideRule {
		return ovRule("https://a.com/**", func(r *overrideRule) { r.GroupID, r.Enabled = group, enabled })
	}
	state := overridesState{MasterEnabled: true, HasGroups: true, Groups: []overrideGroup{
		{ID: groupA, Enabled: true}, {ID: groupB, Enabled: false}}}
	cases := []struct {
		name string
		rule overrideRule
		want bool
	}{
		{"no group, on", in("", true), true},
		{"no group, off", in("", false), false},
		{"group on, rule on", in(groupA, true), true},
		{"group on, rule off", in(groupA, false), false},
		{"group off, rule on", in(groupB, true), false},
		{"unknown group, rule on", in("C0000000-0000-4000-8000-00000000000C", true), true},
	}
	for _, c := range cases {
		if got := state.ruleApplies(c.rule); got != c.want {
			t.Errorf("%s: applies = %v, want %v", c.name, got, c.want)
		}
		if got := state.ruleOn(c.rule); got != c.want {
			t.Errorf("%s: on = %v, want %v", c.name, got, c.want)
		}
	}
	state.MasterEnabled = false
	if state.ruleApplies(in("", true)) || !state.ruleOn(in("", true)) {
		t.Error("the master switch: applies must be off, on must not look at it")
	}

	// A rule in a group that is off doesn't match a request.
	state.MasterEnabled = true
	off := in(groupB, true)
	state.Rules = []overrideRule{off}
	v := testNetViewer(t)
	v.setOverrides(state)
	if _, ok := v.rules.matchingRule("https://a.com/x", "GET"); ok {
		t.Error("a rule in a disabled group matched")
	}
	if text, _ := v.overridesBadge(); text != "" {
		t.Errorf("the Overrides button counts a rule in a disabled group: %q", text)
	}
	state.Groups[1].Enabled = true
	v.setOverrides(state)
	if _, ok := v.rules.matchingRule("https://a.com/x", "GET"); !ok {
		t.Error("a rule in an enabled group didn't match")
	}
}

// The transport follows the capture's source: the proxy for the device proxy and Chrome, flow
// metadata for the companion app, and the platform's agent for the agent or no source yet.
func TestTransportForSource(t *testing.T) {
	cases := []struct {
		platform, source string
		want             transport
	}{
		{"android", "agent", transportAndroidAgent},
		{"iosSimulator", "agent", transportIOSSimulatorAgent},
		{"android", "mitm", transportMITMProxy},
		{"iosSimulator", "mitm", transportMITMProxy},
		{"mac", "browser", transportMITMProxy},
		{"android", "companion", transportCompanionMetadata},
		{"android", "", transportAndroidAgent},
		{"iosSimulator", "", transportIOSSimulatorAgent},
		{"iosDevice", "", transportMITMProxy},
		{"mac", "", transportMITMProxy},
	}
	for _, c := range cases {
		if got := transportFor(c.platform, c.source); got != c.want {
			t.Errorf("transportFor(%q, %q) = %q, want %q", c.platform, c.source, got, c.want)
		}
	}
}

// The new state fields decode, and a jacad without them leaves the offered sources nil.
func TestCaptureStateSetupWire(t *testing.T) {
	var state netState
	if err := json.Unmarshal([]byte(`{"boundPort":8899,"proxyNeedsSetup":true,"caReady":false,"offeredSourceIDs":["mitm"],"selectedSourceID":"mitm"}`), &state); err != nil {
		t.Fatal(err)
	}
	if state.BoundPort != 8899 || !state.ProxyNeedsSetup || state.CAReady || !reflect.DeepEqual(state.OfferedSourceIDs, []string{"mitm"}) {
		t.Errorf("state = %+v", state)
	}
	state = netState{}
	if err := json.Unmarshal([]byte(`{"isRunning":false}`), &state); err != nil || state.OfferedSourceIDs != nil {
		t.Errorf("old state = %+v, %v", state, err)
	}
	state = netState{}
	if err := json.Unmarshal([]byte(`{"offeredSourceIDs":[]}`), &state); err != nil || state.OfferedSourceIDs == nil || len(state.OfferedSourceIDs) != 0 {
		t.Errorf("no offered sources = %#v, %v", state.OfferedSourceIDs, err)
	}
}

// OverrideHostFilter parity: on a device's MITM proxy a rule with routed hosts fires only on
// them; This Mac's Chrome capture and the agent transports apply no host filter.
func TestMatchingRuleOnAppliesTheRoutedHostFilter(t *testing.T) {
	set := compileRules([]overrideRule{
		ovRule("**/v1/users", func(r *overrideRule) { r.Name, r.RoutedHosts = "prod", []string{"API.Prod.com:443"} }),
	}, true)
	cases := []struct {
		name, url, device string
		tr                transport
		want              bool
	}{
		{"another host on the device proxy", "https://api.staging.com/v1/users", "emulator-5554", transportMITMProxy, false},
		{"the routed host, any case and port", "https://api.prod.com:443/v1/users", "emulator-5554", transportMITMProxy, true},
		{"This Mac's browser is not filtered", "http://localhost:3000/v1/users", "mac", transportMITMProxy, true},
		{"the agent is not filtered", "https://api.staging.com/v1/users", "emulator-5554", transportAndroidAgent, true},
	}
	for _, c := range cases {
		if _, got := set.matchingRuleOn(c.url, "GET", c.tr, c.device); got != c.want {
			t.Errorf("%s: matched = %v, want %v", c.name, got, c.want)
		}
	}
	for host, want := range map[string]string{"A.com:443": "a.com", "[::1]:8080": "::1", "::1": "::1", "a.com": "a.com"} {
		if got := normalizeFilterHost(host); got != want {
			t.Errorf("normalizeFilterHost(%q) = %q, want %q", host, got, want)
		}
	}
}
