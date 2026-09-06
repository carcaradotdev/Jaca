// JacaDivert.h — the **entire** on-device response-override surface for the iOS agent.
//
// This is the Objective-C twin of `agent/kotlin/com/squeeze/capture/Divert.kt`: the same contract
// in a second language. It holds a target origin, a set of hostnames, and a heartbeat window.
//
// There are deliberately **no patterns, no payloads, no status codes, no ordering, and nothing
// persisted** here. Rules live on the desktop; this object is a *routing hint*. The device cannot
// express "mock this path", "return 404", "delay 2s" or "rule #3 wins" — it can only answer
// "should this host go through the Mac?". `JacaDivertTargetFor` is one set-membership test.
//
// **The tripwire for review:** any change that adds a path, method, header, body, status, ordering
// or rule-id concept to this file has crossed the line that keeps the agent dumb. The desktop-side
// `OverrideEndpoint` (Sources/Core/Intercept/Intercept.swift) is the single type where such a
// change would show up in a diff — it is the only producer of the frame this file consumes, and
// `Divert.kt` is the other consumer. See `docs/divert-contract.md`.
//
// The origin starts nil, so a freshly injected agent is **read-only by construction**, not by a
// compile-time flag. (Android's predecessor, `PocDivert`, shipped with `ENABLED = true` hard-coded
// — a rebuild silently diverted a hard-coded endpoint. That is why this default matters.)
//
// ### The dead-man switch
// Expiry is checked on the *match path* rather than by a timer thread, so a suspended app, a
// backgrounded process, or a half-open socket can never starve it: if the desktop hasn't spoken
// within the window, the next request disarms and goes direct. Together with the EOF disarm in
// JacaNetChannel and the fail-open retry in JacaNetAgent, a SIGKILLed Jaca cannot leave the user's
// app pointed at a dead loopback port.
//
// **No iOS-only API is used in this file**, on purpose: it compiles for macOS too, so the pure
// decisions below are unit-tested on the host (`Tests/ObjC/JacaDivertTests.m`, target
// `JacaAgentTests`) instead of only being exercised inside a simulator.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - The four wire constants (twins of Divert.kt / OverrideHeaders.swift)

/// Carries the URL the app *meant* to call, so the desktop can route and capture on it.
extern NSString *const kJacaOriginalURLHeader;
/// Response header the desktop sets to bounce a request back for a direct retry.
extern NSString *const kJacaDivertHeader;
/// Value of `kJacaDivertHeader` meaning "I'm not mocking this — send it yourself".
extern NSString *const kJacaRetryDirect;
/// Status paired with `kJacaRetryDirect`. 599 is unassigned, so it can't collide with an origin.
extern const NSInteger kJacaRetryDirectStatus;

#pragma mark - State

/// Applies a desktop control frame. A nil (or empty) `origin` disarms.
///
/// Hosts and window are stored *before* the origin, so no request on another thread can observe a
/// live origin against a stale host set or a stale window.
void JacaDivertConfigure(NSString *_Nullable origin, NSSet<NSString *> *hosts, int heartbeatSeconds);

/// Keeps the dead-man switch fed without changing anything else.
void JacaDivertTouch(void);

/// Goes read-only. Called on socket EOF, on an explicit disarm frame, and on a fail-open retry.
void JacaDivertDisarm(void);

/// True while we'd divert at all — used to skip work on the hot path when read-only.
BOOL JacaDivertIsArmed(void);

/// Applies one `{"type":"divert",…}` control line. `{"type":"ping"}` just feeds the switch.
/// Unknown types are ignored, so the desktop can add frames without breaking an older agent.
void JacaDivertApplyControlLine(NSString *line);

/// The URL string to send this request to instead, or nil to leave it completely alone.
///
/// The dead-man switch is checked **here**, on the match path — never by a timer thread — so a
/// suspended process or a half-open socket can never starve it. Expiry disarms.
///
/// @param host          the request's host; compared case-insensitively
/// @param pathAndQuery  everything after the origin, carried over untouched
NSString *_Nullable JacaDivertTargetFor(NSString *host, NSString *pathAndQuery);

#pragma mark - Pure decisions

/// Everything after the origin — the desktop reconstructs the real URL from
/// `kJacaOriginalURLHeader`, so the path/query only has to survive the hop intact. Percent-encoding
/// is preserved verbatim; an empty path becomes "/"; the fragment is dropped (it is client-side
/// only and never travels on the wire).
NSString *JacaPathAndQuery(NSURL *url);

/// Requests that must never be diverted, because the retry-direct bounce (or a fail-open retry)
/// would have to re-send a body that can only be sent once, or would break a protocol upgrade that
/// isn't plain HTTP on the other side. Anything we can't prove safe is ineligible.
BOOL JacaIsDivertEligible(NSURLRequest *_Nullable req);

/// The URL to send instead, or nil to leave the request alone. Combines armed-ness, eligibility,
/// the host match and the dead-man window.
NSURL *_Nullable JacaDivertTargetURL(NSURLRequest *_Nullable req);

/// The retry-direct bounce, recognised as a **pair** — and only for a request we actually diverted.
///
/// Both halves matter. Keying on the status alone would let any origin returning 599 trigger a
/// retry; keying on status+header without `wasDiverted` would let a real origin that legitimately
/// answers 599 with this header send us round a retry loop forever, since the "retry" is the very
/// same request.
BOOL JacaIsRetryDirectBounce(NSHTTPURLResponse *_Nullable resp, BOOL wasDiverted);

/// Puts the app's original URL back on the response, so a diverted call still looks like the real
/// URL to the app (cookies, logging, anything reading `response.URL`). Status and headers survive.
NSHTTPURLResponse *_Nullable JacaResponseForClient(NSHTTPURLResponse *_Nullable resp,
                                                   NSURL *_Nullable originalURL);

NS_ASSUME_NONNULL_END
