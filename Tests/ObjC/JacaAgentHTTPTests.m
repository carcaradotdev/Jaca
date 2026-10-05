// JacaAgentHTTPTests.m — the agent's decisions, tested on the host.
//
// `agent/iOS/JacaAgentHTTP.m` uses no iOS-only API precisely so this suite can exist: the dead-man
// window, the host match and the 599 bounce pair are the parts where a mistake either makes an app
// uncapturable or leaves it permanently pointed at a dead loopback port, and "rebuild the dylib,
// boot a simulator, launch an app" is far too slow a loop to catch them.
//
// The Kotlin twin (agent/kotlin/com/squeeze/capture/AgentHttp.kt) is the same contract in another
// language; when one changes, this file is where the other's behaviour is written down.

#import <XCTest/XCTest.h>

#import "JacaAgentHTTP.h"

static NSHTTPURLResponse *ResponseWithStatus(NSInteger status, NSDictionary *headers) {
    return [[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:@"http://127.0.0.1:41234/v1/state"]
                                       statusCode:status
                                      HTTPVersion:@"HTTP/1.1"
                                     headerFields:headers];
}

@interface JacaAgentHTTPTests : XCTestCase
@end

@implementation JacaAgentHTTPTests

// The route state is process-global (there is one agent per app), so each test starts read-only.
- (void)setUp { JacaAgentHTTPDisarm(); }
- (void)tearDown { JacaAgentHTTPDisarm(); }

#pragma mark - Host matching

/// Arranged through `JacaAgentHTTPApplyControlLine` with a frame byte-for-byte as
/// `AgentHTTPRoute.routeFrame` emits it, so this also pins the cross-language wire format:
/// hosts sorted, origin as a JSON string, `heartbeatSeconds` alongside.
- (void)test_hostsMatchCaseInsensitivelyFromADesktopFrame {
    JacaAgentHTTPApplyControlLine(
        @"{\"type\":\"divert\",\"origin\":\"http://127.0.0.1:41234\","
        @"\"hosts\":[\"api.example.com\"],\"heartbeatSeconds\":15}");

    XCTAssertTrue(JacaAgentHTTPIsArmed());
    XCTAssertEqualObjects(JacaAgentHTTPTargetFor(@"api.example.com", @"/v1/state"),
                          @"http://127.0.0.1:41234/v1/state");
    // The app's URL can carry any casing; DNS doesn't care and neither may we.
    XCTAssertEqualObjects(JacaAgentHTTPTargetFor(@"API.Example.COM", @"/v1/state"),
                          @"http://127.0.0.1:41234/v1/state");
}

/// A host the desktop never named stays on the device's own network — that is what makes
/// routing a whole host safe.
- (void)test_unlistedHostIsLeftAlone {
    JacaAgentHTTPConfigure(@"http://127.0.0.1:41234", [NSSet setWithObject:@"api.example.com"], 15);
    XCTAssertNil(JacaAgentHTTPTargetFor(@"analytics.example.com", @"/collect"));
}

/// A nil origin is the single spelling of disarm, and the default a fresh agent starts in.
- (void)test_nilOriginRoutesNothing {
    JacaAgentHTTPConfigure(nil, [NSSet setWithObject:@"api.example.com"], 15);
    XCTAssertFalse(JacaAgentHTTPIsArmed());
    XCTAssertNil(JacaAgentHTTPTargetFor(@"api.example.com", @"/v1/state"));
}

#pragma mark - The dead-man switch

/// Expiry doesn't merely decline this request: it **disarms**, so a Jaca that was SIGKILLed leaves
/// the app provably back on its own network with nobody having to run any cleanup.
- (void)test_expiredWindowReturnsNilAndLeavesTheObjectDisarmed {
    JacaAgentHTTPConfigure(@"http://127.0.0.1:41234", [NSSet setWithObject:@"api.example.com"], 0);
    XCTAssertTrue(JacaAgentHTTPIsArmed());
    usleep(2000);   // past a zero-length window

    XCTAssertNil(JacaAgentHTTPTargetFor(@"api.example.com", @"/v1/state"));
    XCTAssertFalse(JacaAgentHTTPIsArmed(), @"expiry must disarm, not just decline one request");
}

/// …and the desktop coming back re-arms it. The heartbeat re-states the whole endpoint for exactly
/// this reason, so a lapsed window repairs itself within one interval.
- (void)test_aFreshFrameReArmsAfterExpiry {
    JacaAgentHTTPConfigure(@"http://127.0.0.1:41234", [NSSet setWithObject:@"api.example.com"], 0);
    usleep(2000);
    XCTAssertNil(JacaAgentHTTPTargetFor(@"api.example.com", @"/v1/state"));

    JacaAgentHTTPConfigure(@"http://127.0.0.1:41234", [NSSet setWithObject:@"api.example.com"], 15);
    XCTAssertEqualObjects(JacaAgentHTTPTargetFor(@"api.example.com", @"/v1/state"),
                          @"http://127.0.0.1:41234/v1/state");
}

#pragma mark - Path and query

- (void)test_pathAndQueryIsCarriedOverUntouched {
    // No path at all still has to produce a request line.
    XCTAssertEqualObjects(JacaPathAndQuery([NSURL URLWithString:@"https://api.example.com"]), @"/");
    XCTAssertEqualObjects(JacaPathAndQuery([NSURL URLWithString:@"https://api.example.com/"]), @"/");

    XCTAssertEqualObjects(JacaPathAndQuery([NSURL URLWithString:@"https://api.example.com/v1/state"]),
                          @"/v1/state");
    // Verbatim, encoding and all: re-encoding a decoded query would change what the origin sees.
    XCTAssertEqualObjects(
        JacaPathAndQuery([NSURL URLWithString:@"https://api.example.com/v1/state?q=a%20b&n=1"]),
        @"/v1/state?q=a%20b&n=1");
    // A fragment is client-side only and never travels on the wire.
    XCTAssertEqualObjects(
        JacaPathAndQuery([NSURL URLWithString:@"https://api.example.com/docs?x=1#section"]),
        @"/docs?x=1");
}

#pragma mark - Eligibility

- (void)test_eligibilityRejectsWhatWeCannotReplay {
    NSURL *url = [NSURL URLWithString:@"https://api.example.com/v1/state"];

    NSMutableURLRequest *plain = [NSMutableURLRequest requestWithURL:url];
    XCTAssertTrue(JacaIsRoutable(plain));

    // A protocol upgrade isn't plain HTTP on the other side.
    NSMutableURLRequest *upgrade = [NSMutableURLRequest requestWithURL:url];
    [upgrade setValue:@"Upgrade" forHTTPHeaderField:@"Connection"];
    XCTAssertFalse(JacaIsRoutable(upgrade));

    // A body stream can only be read once, and both safety nets re-send the request.
    NSMutableURLRequest *streamed = [NSMutableURLRequest requestWithURL:url];
    streamed.HTTPMethod = @"POST";
    streamed.HTTPBodyStream = [NSInputStream inputStreamWithData:[NSData dataWithBytes:"x" length:1]];
    XCTAssertFalse(JacaIsRoutable(streamed));
}

#pragma mark - The retry-direct bounce

/// The four combinations, because recognising the bounce on anything less than all three facts is
/// how you get either a leaked 599 row or an infinite retry loop.
- (void)test_theBounceNeedsTheStatusTheHeaderAndOurOwnRoute {
    NSDictionary *withHeader = @{@"X-Jaca-Divert": @"retry-direct"};

    XCTAssertTrue(JacaIsRetryDirectBounce(ResponseWithStatus(599, withHeader), YES));

    // A real origin that legitimately answers 599 with this header would otherwise send us round
    // the same request forever — the "retry" is that very request.
    XCTAssertFalse(JacaIsRetryDirectBounce(ResponseWithStatus(599, withHeader), NO));

    // 599 alone is somebody else's status code.
    XCTAssertFalse(JacaIsRetryDirectBounce(ResponseWithStatus(599, @{}), YES));

    // And the header alone is not a bounce — the desktop only ever pairs it with 599.
    XCTAssertFalse(JacaIsRetryDirectBounce(ResponseWithStatus(200, withHeader), YES));
}

#pragma mark - Hiding the route from the app

/// A routed call still has to look like the real URL to the app: cookies, logging, and anything
/// reading `response.URL` must never see the loopback one.
- (void)test_theClientSeesTheOriginalURLWithTheRealStatusAndHeaders {
    NSHTTPURLResponse *fromJaca = ResponseWithStatus(201, @{@"Content-Type": @"application/json",
                                                            @"X-Jaca-Override": @"rule-id"});
    NSURL *original = [NSURL URLWithString:@"https://api.example.com/v1/state"];

    NSHTTPURLResponse *forClient = JacaResponseForClient(fromJaca, original);
    XCTAssertEqualObjects(forClient.URL, original);
    XCTAssertEqual(forClient.statusCode, 201);
    XCTAssertEqualObjects([forClient valueForHTTPHeaderField:@"Content-Type"], @"application/json");
    XCTAssertEqualObjects([forClient valueForHTTPHeaderField:@"X-Jaca-Override"], @"rule-id");
}

@end
