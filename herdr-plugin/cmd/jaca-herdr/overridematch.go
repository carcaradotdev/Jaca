package main

import (
	"errors"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"regexp/syntax"
	"sort"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"
)

// The pure logic behind response overrides, ported from OverrideMatching.swift,
// OverrideCompiler.swift, OverrideRowGate.swift and RoutedHostsSync.swift. The daemon decides
// what really happens to a request; this is the same logic run in the pane, for the editor's
// match preview and for the reasons a row or a rule can't be used.

// urlFacts is the parsed shape of a URL (URLFacts). Scheme and Host are lowercased, Port is ""
// unless the URL names one, Path is percent-decoded and starts with "/". Normalized is
// scheme://host[:port]path, what a regex is matched against.
type urlFacts struct {
	Scheme, Host, Port, Path, Normalized string
	Query                                map[string][]string
}

// urlFactsOf parses a URL, false when it isn't HTTP(S). That includes the companion's
// "host:port" flow-metadata rows, which have no request to override.
//
// The app parses with URLComponents and this with net/url, which is stricter: a URL with a
// malformed percent escape ("/100%") parses there and is refused here.
func urlFactsOf(rawURL string) (urlFacts, bool) {
	if rawURL == "" {
		return urlFacts{}, false
	}
	u, err := url.Parse(rawURL)
	if err != nil || u.Hostname() == "" {
		return urlFacts{}, false
	}
	scheme := strings.ToLower(u.Scheme)
	if scheme != "" && scheme != "http" && scheme != "https" {
		return urlFacts{}, false
	}
	f := urlFacts{Scheme: scheme, Host: strings.ToLower(urlHost(u)), Port: u.Port(), Path: u.Path, Query: map[string][]string{}}
	if f.Path == "" {
		f.Path = "/"
	}
	if u.RawQuery != "" {
		for _, item := range strings.Split(u.RawQuery, "&") {
			name, value, _ := strings.Cut(item, "=")
			name, value = percentDecoded(name), percentDecoded(value)
			f.Query[name] = append(f.Query[name], value)
		}
	}
	if scheme != "" {
		f.Normalized = scheme + "://"
	}
	f.Normalized += f.Host
	if f.Port != "" {
		f.Normalized += ":" + f.Port
	}
	f.Normalized += f.Path
	return f, true
}

// urlHost is the host as URLComponents.host gives it: without the port, and with the brackets
// of an IPv6 literal kept.
func urlHost(u *url.URL) string {
	host := u.Hostname()
	if strings.Contains(host, ":") {
		return "[" + host + "]"
	}
	return host
}

// percentDecoded is String.removingPercentEncoding with the original kept when it can't be
// decoded. A "+" stays a "+", as in URLComponents' query items.
func percentDecoded(s string) string {
	decoded, err := url.PathUnescape(s)
	if err != nil || !utf8.ValidString(decoded) {
		return s
	}
	return decoded
}

// Glob tokens: a literal run, "*" (any characters except "/") and "**" (any characters).
const (
	globLiteral = iota
	globStar
	globGlobstar
)

type globToken struct {
	kind    int
	literal []rune
}

// globProgram is a compiled glob (GlobProgram).
type globProgram struct {
	tokens []globToken
	// namesPort is decided from the host portion, so a colon in the path isn't read as a port.
	namesPort bool
	// requiredQuery is what the pattern's own query string asks for.
	requiredQuery map[string]string
}

// compileGlob is OverrideMatching.compileGlob. It fails only on a pattern that is empty once
// trimmed.
//
// The semantics, which the Swift tests freeze:
//   - "*" matches any run of characters except "/", "**" any run including "/"
//   - the pattern must match the whole URL
//   - an omitted scheme matches either; a port is compared only if the pattern names one
//   - scheme and host ignore case; path and query don't
//   - the query is ignored unless the pattern has a "?", and then every k=v in the pattern must
//     be in the request (a value may use "*"); extra parameters and their order don't matter
func compileGlob(pattern string) (globProgram, bool) {
	trimmed := strings.TrimSpace(pattern)
	if trimmed == "" {
		return globProgram{}, false
	}
	head, query, hasQuery := strings.Cut(trimmed, "?")
	required := map[string]string{}
	if hasQuery {
		for _, pair := range strings.Split(query, "&") {
			key, value, _ := strings.Cut(pair, "=")
			if key != "" {
				required[key] = value
			}
		}
	}
	// A fragment is never sent, so it can't be matched.
	head, _, _ = strings.Cut(head, "#")

	// An omitted scheme behaves as "*://".
	body, schemePrefix := head, ""
	if before, after, found := strings.Cut(head, "://"); found {
		schemePrefix, body = strings.ToLower(before), after
	}
	var tokens []globToken
	if schemePrefix == "" || schemePrefix == "*" {
		tokens = append(tokens, globToken{kind: globGlobstar}, globToken{kind: globLiteral, literal: []rune("://")})
	} else {
		tokens = append(tokens, globToken{kind: globLiteral, literal: []rune(schemePrefix + "://")})
	}
	// The host is lowercased and the path percent-decoded, as urlFactsOf does to the URL, so a
	// pattern pasted from an encoded URL compares like for like.
	host, path, hasPath := strings.Cut(body, "/")
	subject := strings.ToLower(host)
	if hasPath {
		subject += percentDecoded("/" + path)
	}
	tokens = append(tokens, tokenizeGlob(subject)...)

	return globProgram{tokens: coalesceGlob(tokens), namesPort: strings.Contains(host, ":"), requiredQuery: required}, true
}

func tokenizeGlob(s string) []globToken {
	var tokens []globToken
	var literal []rune
	flush := func() {
		if len(literal) > 0 {
			tokens = append(tokens, globToken{kind: globLiteral, literal: literal})
			literal = nil
		}
	}
	runes := []rune(s)
	for i := 0; i < len(runes); i++ {
		if runes[i] != '*' {
			literal = append(literal, runes[i])
			continue
		}
		flush()
		if i+1 < len(runes) && runes[i+1] == '*' {
			tokens = append(tokens, globToken{kind: globGlobstar})
			i++
		} else {
			tokens = append(tokens, globToken{kind: globStar})
		}
	}
	flush()
	return tokens
}

// coalesceGlob merges adjacent "**" so "***" and "****" don't multiply the matcher's work.
func coalesceGlob(tokens []globToken) []globToken {
	var out []globToken
	for _, t := range tokens {
		if t.kind == globGlobstar && len(out) > 0 && out[len(out)-1].kind == globGlobstar {
			continue
		}
		out = append(out, t)
	}
	return out
}

// globBacktrack is where one wildcard resumes, so an exhausted wildcard can hand back to the
// one before it.
type globBacktrack struct {
	tokenIndex, subjectIndex int
	isGlobstar               bool
}

// matchGlobTokens is the anchored token match, a port of OverrideMatching.matchTokens: a stack
// of wildcards to backtrack into, and a set of (token, position) pairs known to fail so an
// adversarial pattern can't make it backtrack exponentially. The app compares characters
// (grapheme clusters, canonically equivalent ones equal); this compares code points.
func matchGlobTokens(tokens []globToken, subject string) bool {
	s := []rune(subject)
	ti, si := 0, 0
	var stack []globBacktrack
	failed := map[int]bool{}
	width := len(s) + 1

	for si < len(s) {
		state := ti*width + si
		if !failed[state] && ti < len(tokens) {
			token := tokens[ti]
			if token.kind != globLiteral {
				stack = append(stack, globBacktrack{ti, si, token.kind == globGlobstar})
				ti++
				continue
			}
			if runesAt(s, si, token.literal) {
				si += len(token.literal)
				ti++
				continue
			}
		}
		// A mismatch: the most recent wildcard takes one more character, and when it can't,
		// the one before it does.
		failed[state] = true
		resumed := false
		for len(stack) > 0 && !resumed {
			top := stack[len(stack)-1]
			stack = stack[:len(stack)-1]
			next := top.subjectIndex + 1
			// "*" must not cross a path separator; "**" may.
			if next > len(s) || (!top.isGlobstar && s[next-1] == '/') {
				continue
			}
			top.subjectIndex = next
			stack = append(stack, top)
			ti, si = top.tokenIndex+1, next
			resumed = true
		}
		if !resumed {
			return false
		}
	}
	// Trailing wildcards may match nothing.
	for ; ti < len(tokens); ti++ {
		if tokens[ti].kind == globLiteral {
			return false
		}
	}
	return true
}

func runesAt(s []rune, at int, want []rune) bool {
	if at+len(want) > len(s) {
		return false
	}
	for i, r := range want {
		if s[at+i] != r {
			return false
		}
	}
	return true
}

func (p globProgram) matches(f urlFacts) bool {
	for key, wanted := range p.requiredQuery {
		values, present := f.Query[key]
		if !present {
			return false
		}
		if wanted == "*" || wanted == "" {
			continue
		}
		found := false
		for _, value := range values {
			if strings.Contains(wanted, "*") {
				found = matchGlobTokens(tokenizeGlob(wanted), value)
			} else {
				found = value == wanted
			}
			if found {
				break
			}
		}
		if !found {
			return false
		}
	}
	// A pattern that names no port is compared against the URL without its port, so
	// "api.x.com/**" matches "https://api.x.com:443/v1" too.
	subject := f.Host
	if f.Scheme != "" {
		subject = f.Scheme + "://" + subject
	}
	if p.namesPort && f.Port != "" {
		subject += ":" + f.Port
	}
	return matchGlobTokens(p.tokens, subject+f.Path)
}

// anchorRegex is OverrideCompiler.anchor: a regex must match the whole URL.
func anchorRegex(pattern string) string {
	if !strings.HasPrefix(pattern, "^") {
		pattern = "^" + pattern
	}
	if !strings.HasSuffix(pattern, "$") {
		pattern += "$"
	}
	return pattern
}

// compiledRule is a rule with its pattern compiled (CompiledRule). A glob has a program, a
// regex has a regex.
type compiledRule struct {
	rule    overrideRule
	program *globProgram
	regex   *regexp.Regexp
}

// compileRule compiles one rule's matcher, with the diagnostic for a pattern that doesn't
// compile.
//
// Regexes run on Go's regexp (RE2), the app's on NSRegularExpression (ICU). RE2 has no
// lookaround, backreferences or possessive quantifiers, so a pattern using them works in the
// app and the daemon and fails to compile here: the pane then reports the rule as invalid and
// its match preview says nothing matches, while the daemon applies the rule. regexMayNeedICU
// tells such a pattern from one that is wrong everywhere. Patterns both engines compile can
// still differ at the edges (\d, \w and \b are ASCII-only in RE2).
func compileRule(r overrideRule) (compiledRule, string) {
	if r.Matcher.Kind == "regex" {
		re, err := regexp.Compile("(?i)" + anchorRegex(r.Matcher.Pattern))
		if err != nil {
			return compiledRule{}, "This regular expression isn't valid."
		}
		return compiledRule{rule: r, regex: re}, ""
	}
	program, ok := compileGlob(r.Matcher.Pattern)
	if !ok {
		return compiledRule{}, "This override has no URL pattern."
	}
	return compiledRule{rule: r, program: &program}, ""
}

// matches is OverrideMatching.matches. The method set is compared as stored against the
// request's method in uppercase.
func (c compiledRule) matches(f urlFacts, method string) bool {
	if methods := c.rule.Matcher.Methods; len(methods) > 0 && !containsString(methods, strings.ToUpper(method)) {
		return false
	}
	if c.regex != nil {
		return c.regex.MatchString(f.Normalized)
	}
	return c.program != nil && c.program.matches(f)
}

// ruleSet is the compiled rule library, in precedence order (OverrideCompiler.compile): the
// enabled rules whose pattern compiled, and a diagnostic for each enabled rule that can't fire.
type ruleSet struct {
	rules         []compiledRule
	masterEnabled bool
	diagnostics   map[string]string // by rule id
}

func compileRules(rules []overrideRule, masterEnabled bool) ruleSet {
	set := ruleSet{masterEnabled: masterEnabled, diagnostics: map[string]string{}}
	for _, r := range rules {
		if !r.Enabled {
			continue
		}
		compiled, diagnostic := compileRule(r)
		if diagnostic == "" {
			set.rules = append(set.rules, compiled)
		} else {
			set.diagnostics[strings.ToUpper(r.ID)] = diagnostic
		}
		// A rule whose body is gone still compiles and matches; the diagnostic says it has
		// nothing to serve.
		if reason := bodyDiagnostic(r); reason != "" {
			set.diagnostics[strings.ToUpper(r.ID)] = reason
		}
	}
	return set
}

// bodyDiagnostic is OverrideBodyLoader.unavailableReason for the rule's body: why it can't be
// served, "" when it can. It looks at this machine's disk, which the daemon shares.
func bodyDiagnostic(r overrideRule) string {
	body := r.Action.body()
	if body == nil {
		return ""
	}
	switch body.Kind {
	case "blob":
		if !fileExists(filepath.Join(overrideBodiesDir(), body.Filename)) {
			return "This override's saved body is missing."
		}
	case "file":
		if !fileExists(body.Path) {
			return "Override file is missing: " + body.Path
		}
	}
	return ""
}

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

// firstMatch is the first enabled rule that matches the request and whose scope takes the
// device and app; an empty deviceID or appID is an unknown one. First match wins, in list
// order. The master switch is not applied here: callers decide.
func (s ruleSet) firstMatch(url, method, deviceID, appID string) (overrideRule, bool) {
	if matches := s.matching(url, method, deviceID, appID, false, true); len(matches) > 0 {
		return matches[0], true
	}
	return overrideRule{}, false
}

// allMatches is every enabled rule matching the request, in precedence order: the first is the
// one that runs and the rest are shadowed by it.
func (s ruleSet) allMatches(url, method, deviceID, appID string) []overrideRule {
	return s.matching(url, method, deviceID, appID, false, false)
}

// matching is the enabled rules that match, in order. hostFilter limits each rule with routed
// hosts to those hosts (OverrideHostFilter).
func (s ruleSet) matching(url, method, deviceID, appID string, hostFilter, firstOnly bool) []overrideRule {
	facts, ok := urlFactsOf(url)
	if !ok {
		return nil
	}
	var out []overrideRule
	for _, c := range s.rules {
		if hostFilter && !hostFilterAllows(c.rule.RoutedHosts, facts.Host) {
			continue
		}
		if c.rule.Scope.matches(deviceID, appID) && c.matches(facts, method) {
			out = append(out, c.rule)
			if firstOnly {
				break
			}
		}
	}
	return out
}

// matchingRule is OverridesModel.matchingRule: the first enabled rule matching the request,
// whatever the transport and the master switch. It asks with no device and no app, as the app
// does, so a rule scoped to particular devices or apps is not reported.
func (s ruleSet) matchingRule(url, method string) (overrideRule, bool) {
	return s.firstMatch(url, method, "", "")
}

// matchingRuleOn is matchingRule with the routed-host filter the runtime applies at transport
// tr for deviceID, so a row never claims a rule the MITM proxy would skip.
func (s ruleSet) matchingRuleOn(url, method string, tr transport, deviceID string) (overrideRule, bool) {
	if matches := s.matching(url, method, "", "", hostFilterApplies(tr, deviceID), true); len(matches) > 0 {
		return matches[0], true
	}
	return overrideRule{}, false
}

// hostFilterApplies is OverrideHostFilter.applies: the MITM proxy of a device filters by
// routed host; This Mac's Chrome capture, also mitmProxy, does not.
func hostFilterApplies(tr transport, deviceID string) bool {
	return tr == transportMITMProxy && deviceID != "mac"
}

// hostFilterAllows is OverrideHostFilter.allows once the filter applies: a rule with no routed
// hosts fires on every host.
func hostFilterAllows(routed []string, host string) bool {
	if len(routed) == 0 {
		return true
	}
	want := normalizeFilterHost(host)
	for _, h := range routed {
		if normalizeFilterHost(h) == want {
			return true
		}
	}
	return false
}

// normalizeFilterHost is OverrideHostFilter.normalize: lowercase, without a ":port". An IPv6
// literal keeps its colons; only the bracketed form loses its port and brackets.
func normalizeFilterHost(host string) string {
	h := strings.ToLower(strings.TrimSpace(host))
	if strings.HasPrefix(h, "[") {
		if end := strings.Index(h, "]"); end > 0 {
			return h[1:end]
		}
	}
	if strings.Count(h, ":") == 1 {
		h = h[:strings.Index(h, ":")]
	}
	return h
}

// routedHosts is the hosts a device transport routes through the Mac for this device and app:
// the routed hosts of the enabled rules in scope, sorted, and none while the master switch is
// off.
func (s ruleSet) routedHosts(deviceID, appID string) []string {
	if !s.masterEnabled {
		return nil
	}
	seen := map[string]bool{}
	var hosts []string
	for _, c := range s.rules {
		if !c.rule.Scope.matches(deviceID, appID) {
			continue
		}
		for _, host := range c.rule.RoutedHosts {
			if !seen[host] {
				seen[host] = true
				hosts = append(hosts, host)
			}
		}
	}
	sort.Strings(hosts)
	return hosts
}

// diagnostic is why an enabled rule can't fire (a pattern that doesn't compile, a missing
// body), "" when nothing is wrong with it.
func (s ruleSet) diagnostic(ruleID string) string {
	return s.diagnostics[strings.ToUpper(ruleID)]
}

// ruleMatches compiles r as if it were enabled and matches it against the request, false when
// the pattern doesn't compile or the URL isn't HTTP(S). For the editor's match preview.
func ruleMatches(r overrideRule, url, method string) bool {
	compiled, diagnostic := compileRule(r)
	facts, ok := urlFactsOf(url)
	return diagnostic == "" && ok && compiled.matches(facts, method)
}

// patternError is OverrideEditorSheet.patternError: why the pattern can't be saved, "" when it
// compiles. An empty pattern is not an error here. For a regex the text is Go's regexp error,
// where the app shows NSRegularExpression's; see compileRule for patterns only Go refuses.
func patternError(m ruleMatcher) string {
	if m.Pattern == "" {
		return ""
	}
	if m.Kind == "regex" {
		if _, err := regexp.Compile(anchorRegex(m.Pattern)); err != nil {
			return err.Error()
		}
		return ""
	}
	if _, ok := compileGlob(m.Pattern); !ok {
		return "This pattern isn't valid."
	}
	return ""
}

// regexMayNeedICU reports whether a regex fails to compile here for using syntax RE2 lacks and
// ICU has (lookaround, backreferences, possessive quantifiers, repeat counts over 1000), so the
// app and the daemon may well accept it. False for a pattern that compiles.
func regexMayNeedICU(pattern string) bool {
	_, err := regexp.Compile(anchorRegex(pattern))
	var syntaxErr *syntax.Error
	if !errors.As(err, &syntaxErr) {
		return false
	}
	switch syntaxErr.Code {
	case syntax.ErrInvalidPerlOp, syntax.ErrInvalidEscape, syntax.ErrInvalidRepeatOp,
		syntax.ErrInvalidRepeatSize, syntax.ErrInvalidNamedCapture:
		return true
	}
	return false
}

// literalHost is OverrideMatching.literalHost(ofPattern:): the hostname a pattern names, in
// lowercase, false when the host is empty or wildcarded.
func literalHost(pattern string) (string, bool) {
	body := strings.TrimSpace(pattern)
	if _, after, found := strings.Cut(body, "://"); found {
		body = after
	}
	hostPart, _, _ := strings.Cut(body, "/")
	host := hostPart
	for _, part := range strings.Split(hostPart, ":") {
		if part != "" {
			host = part
			break
		}
	}
	if host == "" || strings.Contains(host, "*") {
		return "", false
	}
	return strings.ToLower(host), true
}

// derivedRoutedHosts is the routed hosts a matcher implies: the glob's literal host, or none
// for a wildcarded host or any regex. None makes the editor ask, so nothing is ever routed
// wholesale.
func derivedRoutedHosts(m ruleMatcher) []string {
	if m.Kind == "regex" {
		return nil
	}
	if host, ok := literalHost(m.Pattern); ok {
		return []string{host}
	}
	return nil
}

// generalizePattern is OverrideMatching.generalize: path segments that look like an id (all
// digits, a UUID, a long token of letters and digits) become "*".
func generalizePattern(pattern string) string {
	origin, rest, found := strings.Cut(pattern, "://")
	if !found {
		return pattern
	}
	slash := strings.Index(rest, "/")
	if slash < 0 {
		return pattern
	}
	segments := strings.Split(rest[slash:], "/")
	for i, segment := range segments {
		if looksLikeID(segment) {
			segments[i] = "*"
		}
	}
	return origin + "://" + rest[:slash] + strings.Join(segments, "/")
}

func looksLikeID(s string) bool {
	if s == "" {
		return false
	}
	runes := []rune(s)
	allNumbers, allHex, allToken := true, true, true
	hasNumber, hasLetter := false, false
	for _, r := range runes {
		number, letter := unicode.IsNumber(r), unicode.IsLetter(r)
		hasNumber, hasLetter = hasNumber || number, hasLetter || letter
		allNumbers = allNumbers && number
		allHex = allHex && r < utf8.RuneSelf && isHexByte(byte(r))
		allToken = allToken && (number || letter || r == '-' || r == '_')
	}
	switch {
	case allNumbers, isUUID(s), len(runes) == 32 && allHex:
		return true
	}
	// A long opaque token (an id, a hash) with both letters and digits.
	return len(runes) >= 16 && hasNumber && hasLetter && allToken
}

// interceptSkip is why no rule was applied (InterceptSkipReason). The zero value is no reason:
// the rule runs.
type interceptSkip struct {
	Kind      string // "", "masterOff", "transportUnsupported", "transportNotArmed", "noRuleMatched"
	Transport transport
	Missing   int    // the capabilities the transport lacks, for transportUnsupported
	Detail    string // the transport's own words, for transportNotArmed
}

// message is InterceptSkipReason.message.
func (s interceptSkip) message() string {
	switch s.Kind {
	case "masterOff":
		return "Overrides are paused."
	case "transportUnsupported":
		if s.Missing&capBodies != 0 {
			return "This rule needs response bodies, which " + s.Transport.label() + " capture doesn't provide."
		}
		if s.Missing&capMapRemote != 0 {
			return "Redirecting to another origin isn't supported by " + s.Transport.label() + " capture."
		}
		return "This rule can't run in " + s.Transport.label() + " capture."
	case "transportNotArmed":
		return s.Detail
	case "noRuleMatched":
		return "No override matched this request."
	}
	return ""
}

// ruleDecision is what the clamp decided for a matching rule (InterceptDecision without the
// response itself): Action is "proceed", "respond" or "edit".
type ruleDecision struct {
	Action string
	Delay  time.Duration
	RuleID string
}

// decideRule is OverrideMatching.decide, the one place a rule is clamped to what a capture can
// do. r is the rule that matched, nil when none did.
func decideRule(r *overrideRule, t transport, capabilities int, masterEnabled bool) (ruleDecision, interceptSkip) {
	proceed := ruleDecision{Action: "proceed"}
	if !masterEnabled {
		return proceed, interceptSkip{Kind: "masterOff"}
	}
	if r == nil || !r.Enabled {
		return proceed, interceptSkip{Kind: "noRuleMatched"}
	}
	if missing := r.Action.requiredCapabilities() &^ capabilities; missing != 0 {
		return proceed, interceptSkip{Kind: "transportUnsupported", Transport: t, Missing: missing}
	}
	var delay time.Duration
	if capabilities&capDelay != 0 && r.DelayMillis > 0 {
		delay = time.Duration(r.DelayMillis) * time.Millisecond
	}
	switch r.Action.Kind {
	case "editResponse":
		return ruleDecision{Action: "edit", Delay: delay, RuleID: r.ID}, interceptSkip{}
	case "mapRemote":
		// Modelled but not executable yet, even on a transport that declares the capability.
		return proceed, interceptSkip{Kind: "transportUnsupported", Transport: t, Missing: capMapRemote}
	}
	return ruleDecision{Action: "respond", Delay: delay, RuleID: r.ID}, interceptSkip{}
}

// skipReason is why a matching rule can't run on a capture, "" when it can
// (OverrideMatching.decide + InterceptSkipReason.message).
func skipReason(r overrideRule, t transport, capabilities int, masterEnabled bool) string {
	_, skip := decideRule(&r, t, capabilities, masterEnabled)
	return skip.message()
}

// rowGateReason is OverrideRowGate.unavailableReason, "" when a row can be overridden. running
// is whether a capture source is running, and arming what its transport last reported.
func rowGateReason(t transport, txn netTransaction, running bool, arming armingState) string {
	return rowGate(t, arming, running, true, txn.URL, txn.HTTPStack)
}

// rowGate answers whether a captured row can seed a rule, not whether the rule would fire now:
// only reasons that make the row itself unusable belong here. httpStack is consulted for the
// Android agent alone, and "" is an unknown stack, which never blocks.
func rowGate(t transport, arming armingState, running, overridesAvailable bool, url, httpStack string) string {
	if !overridesAvailable {
		return "Response overrides aren't available."
	}
	// Companion flow-metadata rows are "host:port": no method, path or body to override.
	if _, ok := urlFactsOf(url); !ok {
		return "This row is flow metadata, not an HTTP request."
	}
	switch t {
	case transportCompanionMetadata:
		return "Overrides apply to in-process agent capture. Companion capture will follow."
	case transportAndroidAgent:
		if httpStack != "" && httpStack != "okhttp3" {
			return "This request came from " + stackLabel(httpStack) + ", not okhttp3 — Jaca can't divert it."
		}
	}
	// Arming states only mean something while a source runs: with capture stopped, idle is no
	// reason to refuse a rule.
	if running && arming.State == "detached" {
		return arming.blockedMessage()
	}
	return ""
}

// routedHostsSync keeps a rule's routed hosts in step with its pattern while it is edited
// (RoutedHostsSync.State). Hosts is the set in the hosts field; IsDerived says it came from the
// pattern and not from the user. A derived set is replaced or dropped when the pattern changes;
// a typed one is only replaced by a pattern that names a host.
//
// The three operations: initialRoutedHosts when a rule opens, afterMatcherChange when the
// pattern or the glob/regex choice changes, routedHostsAfterUserEdit when the user types hosts.
type routedHostsSync struct {
	Hosts     []string
	IsDerived bool
}

// initialRoutedHosts is how a rule opens: derived only if its saved hosts are exactly what its
// pattern implies.
func initialRoutedHosts(hosts, derived []string) routedHostsSync {
	return routedHostsSync{Hosts: hosts, IsDerived: len(derived) > 0 && sameStringSet(hosts, derived)}
}

// afterMatcherChange takes what the new matcher implies (derivedRoutedHosts). A pattern that
// names a host sets the hosts. One that doesn't drops hosts derived from an earlier pattern,
// which are stale, and keeps hosts the user typed.
func (s routedHostsSync) afterMatcherChange(derived []string) routedHostsSync {
	if len(derived) > 0 {
		return routedHostsSync{Hosts: derived, IsDerived: true}
	}
	if !s.IsDerived {
		return s
	}
	return routedHostsSync{}
}

// routedHostsAfterUserEdit is the state once the user typed into the hosts field: the set is
// theirs from then on.
func routedHostsAfterUserEdit(hosts []string) routedHostsSync {
	return routedHostsSync{Hosts: hosts}
}

func sameStringSet(a, b []string) bool {
	set := map[string]bool{}
	for _, s := range a {
		set[s] = true
	}
	other := map[string]bool{}
	for _, s := range b {
		if !set[s] {
			return false
		}
		other[s] = true
	}
	return len(set) == len(other)
}
