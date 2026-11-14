package main

import (
	"bytes"
	"crypto/rand"
	"encoding/json"
	"fmt"
	"io"
	"net/url"
	"strings"
	"time"
	"unicode/utf8"
)

// headerPair mirrors HeaderPair. A missing name or value decodes as "".
type headerPair struct {
	Name  string `json:"name"`
	Value string `json:"value"`
}

// netTransaction mirrors NetworkTransaction's wire format. Bodies are absent on events and
// lists; BodiesEvicted says there are bodies to fetch with network.body.
//
// The wire omits what the app holds as nil, so "" stands for a missing responseContentType,
// error, overriddenByRuleID and httpStack. An httpStack of "" is unknown, never unsupported.
type netTransaction struct {
	ID                  string       `json:"id"`
	Method              string       `json:"method"`
	URL                 string       `json:"url"`
	Host                string       `json:"host"`
	Scheme              string       `json:"scheme"`
	RequestHeaders      []headerPair `json:"requestHeaders"`
	ResponseHeaders     []headerPair `json:"responseHeaders"`
	StatusCode          *int         `json:"statusCode"`
	ResponseContentType string       `json:"responseContentType"`
	StartedAt           time.Time    `json:"startedAt"`
	ResponseReceivedAt  *time.Time   `json:"responseReceivedAt"`
	FinishedAt          *time.Time   `json:"finishedAt"`
	RequestBytes        int          `json:"requestBytes"`
	ResponseBytes       int          `json:"responseBytes"`
	Error               string       `json:"error"`
	CallStack           []string     `json:"callStack"`
	BodiesEvicted       bool         `json:"bodiesEvicted"`
	OverriddenByRuleID  string       `json:"overriddenByRuleID"`
	HTTPStack           string       `json:"httpStack"`
}

// statusText is NetworkTransaction.statusText: "ERR" for a failed request, "…" while there is
// no status yet, otherwise the code.
func (t netTransaction) statusText() string {
	if t.Error != "" {
		return "ERR"
	}
	if t.StatusCode == nil {
		return "…"
	}
	return fmt.Sprint(*t.StatusCode)
}

// path is NetworkTransaction.path: the URL's decoded path, or, when it has none, the whole URL
// if it starts with the scheme and "/" otherwise.
func (t netTransaction) path() string {
	if p := decodedURLPath(t.URL); p != "" {
		return p
	}
	if strings.HasPrefix(t.URL, t.Scheme) {
		return t.URL
	}
	return "/"
}

// decodedURLPath is URLComponents(string:)?.path: the percent-decoded path, "" when the text
// doesn't parse or has none. For "host:port", which parses as a scheme and an opaque rest, the
// rest is the path, as URLComponents has it.
func decodedURLPath(rawURL string) string {
	u, err := url.Parse(rawURL)
	if err != nil {
		return ""
	}
	if u.Path == "" && u.Opaque != "" {
		if decoded, err := url.PathUnescape(u.Opaque); err == nil {
			return decoded
		}
		return u.Opaque
	}
	return u.Path
}

// duration is the total time once the request finished.
func (t netTransaction) duration() (time.Duration, bool) {
	if t.FinishedAt == nil {
		return 0, false
	}
	return t.FinishedAt.Sub(t.StartedAt), true
}

// ttfb is the time to the first response byte.
func (t netTransaction) ttfb() (time.Duration, bool) {
	if t.ResponseReceivedAt == nil {
		return 0, false
	}
	return t.ResponseReceivedAt.Sub(t.StartedAt), true
}

// isJacaInternalHeader is JacaHeaders.isJacaInternal: the X-Jaca-* headers are Jaca's own
// markers, not something the app or the server sent.
func isJacaInternalHeader(name string) bool {
	return strings.HasPrefix(strings.ToLower(name), "x-jaca-")
}

func withoutJacaHeaders(headers []headerPair) []headerPair {
	var kept []headerPair
	for _, h := range headers {
		if !isJacaInternalHeader(h.Name) {
			kept = append(kept, h)
		}
	}
	return kept
}

func (t netTransaction) displayRequestHeaders() []headerPair {
	return withoutJacaHeaders(t.RequestHeaders)
}

func (t netTransaction) displayResponseHeaders() []headerPair {
	return withoutJacaHeaders(t.ResponseHeaders)
}

// requestContentType is the request's content-type header value, "" when it has none.
func (t netTransaction) requestContentType() string {
	for _, h := range t.RequestHeaders {
		if strings.EqualFold(h.Name, "content-type") {
			return h.Value
		}
	}
	return ""
}

// netState mirrors NetworkCaptureState. A missing or unreadable attachState is idle.
type netState struct {
	IsRunning             bool        `json:"isRunning"`
	IsConnecting          bool        `json:"isConnecting"`
	StatusMessage         string      `json:"statusMessage"`
	SelectedSourceID      string      `json:"selectedSourceID"`
	HasSelectedMode       bool        `json:"hasSelectedMode"`
	TargetPackage         string      `json:"targetPackage"`
	AttachState           armingState `json:"attachState"`
	InterceptWired        bool        `json:"interceptWired"`
	InterceptCapabilities int         `json:"interceptCapabilities"`
	HasRunningSource      bool        `json:"hasRunningSource"`
	BoundPort             int         `json:"boundPort"`
	ProxyNeedsSetup       bool        `json:"proxyNeedsSetup"`
	CAReady               bool        `json:"caReady"`
	// The sources the chooser offers in the current mode. nil when jacad doesn't send them (a
	// jacad from before the mode); an empty list when the device has none.
	OfferedSourceIDs []string `json:"offeredSourceIDs"`
}

// The capture source ids that network.select takes (HTTPDebuggingSourceID).
const (
	sourceAgent     = "agent"
	sourceMITM      = "mitm"
	sourceBrowser   = "browser"
	sourceCompanion = "companion"
)

// The network inspection modes, by their wire names (NetworkInspectionMode.wireName).
const (
	modeAgent = "agent"
	modeMITM  = "mitm"
)

// netModeState mirrors NetworkModeController.State: the result of network.mode and the payload
// of the network.mode topic.
type netModeState struct {
	Mode      string `json:"mode"`
	Switching bool   `json:"switching"`
}

// installCAResult mirrors NetworkArea.InstallCAResult. Outcome is "installed", "needsUser" or
// "failed". Message is set only for "failed", and RebootAdvised only after a simulator install.
type installCAResult struct {
	Outcome       string `json:"outcome"`
	Message       string `json:"message"`
	RebootAdvised bool   `json:"rebootAdvised"`
}

// formatNetSize is NetworkFormatting.size.
func formatNetSize(bytes int) string {
	switch {
	case bytes <= 0:
		return "—"
	case bytes < 1024:
		return fmt.Sprintf("%d B", bytes)
	case bytes < 1024*1024:
		return fmt.Sprintf("%.1f KB", float64(bytes)/1024)
	}
	return fmt.Sprintf("%.1f MB", float64(bytes)/(1024*1024))
}

// formatNetDuration is NetworkFormatting.duration: whole milliseconds under a second, seconds
// with two decimals from there, "—" when there is no duration yet.
func formatNetDuration(d time.Duration, ok bool) string {
	if !ok {
		return "—"
	}
	if d < time.Second {
		return fmt.Sprintf("%d ms", d.Milliseconds())
	}
	return fmt.Sprintf("%.2f s", d.Seconds())
}

// netBodyText is NetworkFormatting.bodyText: JSON pretty-printed with sorted keys when the
// content type says JSON and the body parses, other text as it is, and a size summary for
// bytes that aren't UTF-8.
func netBodyText(body []byte, contentType string) string {
	if len(body) == 0 {
		return ""
	}
	if pretty, ok := prettyJSON(body, contentType); ok {
		return string(pretty)
	}
	if utf8.Valid(body) {
		return string(body)
	}
	return "<" + formatNetSize(len(body)) + " binary data>"
}

// prettyJSON reformats a JSON object or array with sorted keys and a two-space indent, when the
// content type contains "json". A bare number or string is left alone, as JSONSerialization
// rejects a top-level fragment. Numbers keep the digits they were written with.
func prettyJSON(data []byte, contentType string) ([]byte, bool) {
	if !strings.Contains(strings.ToLower(contentType), "json") {
		return nil, false
	}
	trimmed := bytes.TrimLeft(data, " \t\r\n")
	if len(trimmed) == 0 || (trimmed[0] != '{' && trimmed[0] != '[') {
		return nil, false
	}
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.UseNumber()
	var value any
	if dec.Decode(&value) != nil {
		return nil, false
	}
	// Anything after the first value makes the body invalid JSON.
	if _, err := dec.Token(); err != io.EOF {
		return nil, false
	}
	var out bytes.Buffer
	enc := json.NewEncoder(&out)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	if enc.Encode(value) != nil {
		return nil, false
	}
	return bytes.TrimRight(out.Bytes(), "\n"), true
}

// newUUID is a random (version 4) UUID in the form Swift's uuidString prints: uppercase, with
// dashes. The daemon keys rules and transactions by that form.
func newUUID() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		// No entropy source: fall back to the clock, so the id is still unique in this process.
		now := uint64(time.Now().UnixNano())
		for i := range b {
			b[i] = byte(now >> (8 * (i % 8)))
			now = now*6364136223846793005 + 1442695040888963407
		}
	}
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	return fmt.Sprintf("%X-%X-%X-%X-%X", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}

// isUUID reports whether s has the 8-4-4-4-12 hex form UUID(uuidString:) accepts.
func isUUID(s string) bool {
	if len(s) != 36 {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch i {
		case 8, 13, 18, 23:
			if c != '-' {
				return false
			}
		default:
			if !isHexByte(c) {
				return false
			}
		}
	}
	return true
}

func isHexByte(c byte) bool {
	return c >= '0' && c <= '9' || c >= 'a' && c <= 'f' || c >= 'A' && c <= 'F'
}
