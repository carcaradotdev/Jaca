// JacaNetAgent.m — in-process network capture for iOS Simulator apps, no CA / no proxy.
//
// Injected into a debug app via SIMCTL_CHILD_DYLD_INSERT_LIBRARIES (set by Jaca when it
// launches the app on the simulator). On load it connects back to Jaca on
// 127.0.0.1:$JACA_NET_PORT (the simulator shares the Mac's loopback) and registers an
// NSURLProtocol that taps the URL-loading system. Every request is replayed through a
// private session (so we see plaintext request+response, before/after TLS) and reported
// as one newline-delimited JSON line per completed request — the SAME schema Jaca's
// AgentTransactionParser already parses for the Android agent.
//
// This file is the **tap and the divert client**. The transport lives in JacaNetChannel and the
// routing state in JacaDivert; those two are deliberately separate, but the tap and the client are
// not, because they interleave across three delegate methods and share the `diverted` flag that
// makes the 599 bounce safe.
//
// Build (Jaca's project.yml postBuildScript compiles every agent/iOS/*.m into
// Jaca.app/Contents/Resources):
//   xcrun -sdk iphonesimulator clang -dynamiclib -fobjc-arc \
//     -target arm64-apple-ios15.0-simulator -framework Foundation -o JacaNetAgent.dylib agent/iOS/*.m

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <os/lock.h>

#import "JacaDivert.h"
#import "JacaNetChannel.h"

#pragma mark - Frame helpers

/// A body as a JSON string, or **nil to omit the key entirely**.
///
/// JSON strings can't hold invalid UTF-8, and this used to report non-text bodies (images,
/// protobuf) as a `<N bytes binary>` placeholder. The desktop parser can't tell a placeholder from
/// a body that genuinely says that, so a row showed a fabricated text body it never received.
/// Omitting the key makes it "no body captured"; `requestSize`/`responseSize` still carry the truth.
/// Mirrors `SqueezeTracker.BODY_CAP` on Android. Reported bodies are for inspection, not for
/// replay, so holding an unbounded one only risks an OOM in the *user's* app.
static const NSUInteger kJacaBodyCap = 1024 * 1024;
/// What the response buffer may hold: the cap plus one maximal UTF-8 sequence. Stopping at
/// *exactly* the cap made `bodyText` take its `<= kJacaBodyCap` fast path, skipping the boundary
/// walk — so a truncated body with a multi-byte character at the cut still decoded to nil.
static const NSUInteger kJacaBodyRoom = kJacaBodyCap + 4;

/// The reported body: at most `kJacaBodyCap`, so one large upload can't put hundreds of MB
/// through `-[NSString initWithData:]` and then onto the control socket as a single JSON line.
/// The `requestSize`/`responseSize` fields stay exact, so the desktop still shows the true size.
static NSString *_Nullable bodyText(NSData *data) {
    if (data.length == 0) return nil;
    if (data.length <= kJacaBodyCap) {
        return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    }
    // Cutting at exactly the cap can land mid-sequence, and `initWithData:` then returns **nil**
    // for the whole thing — so a >1 MB body with any multi-byte character anywhere near the
    // boundary showed as no body at all, which is worse than the truncation it replaced. Back up
    // to the start of the code point (continuation bytes are 10xxxxxx); at most 3 steps.
    NSUInteger end = kJacaBodyCap;
    const uint8_t *bytes = data.bytes;
    while (end > 0 && (bytes[end] & 0xC0) == 0x80) { end--; }
    return [[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(0, end)]
                                 encoding:NSUTF8StringEncoding];
}

static NSDictionary *headerDict(NSDictionary *h) { return h ?: @{}; }

#pragma mark - NSURLProtocol interceptor

static NSString *const kHandled = @"JacaHandled";

@interface JacaURLProtocol : NSURLProtocol <NSURLSessionDataDelegate>
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSMutableData *respData;
/// Every byte the response carried, including any past `kJacaBodyCap` that `respData` dropped —
/// so `responseSize` stays honest while the buffer stays bounded.
@property (nonatomic, assign) NSUInteger respBytes;
/// Whether `captureRequestBody` drained `HTTPBodyStream`. A drained stream is exhausted and must
/// never be forwarded, *including* when it yielded zero bytes.
@property (nonatomic, assign) BOOL drainedRequestStream;
@property (nonatomic, strong) NSHTTPURLResponse *resp;
@property (nonatomic, strong) NSData *reqBody;
@property (nonatomic) NSTimeInterval startedAt;
@property (nonatomic) NSTimeInterval responseAt;
/// True while the request in flight is pointed at Jaca instead of the real origin. Guards the
/// 599 bounce check, so a real origin answering 599 can't send us round a retry loop.
@property (nonatomic) BOOL diverted;
/// We fail open at most once per request; a genuinely broken origin must not be retried forever.
@property (nonatomic) BOOL failedOpen;
@end

@implementation JacaURLProtocol {
    /// Guards the `_task` / `_stopped` pair — the only two fields written from one thread and read
    /// from another. `-stopLoading` runs on the URL-loading thread while the three delegate methods
    /// (and `retryDirect`, which *writes* `_task`) run on the session's delegate queue, so without
    /// this the reassignment in `retryDirect` is an unsynchronised ARC retain/release against
    /// `-stopLoading`'s read, and a cancel could be observed half-applied. ARC zero-fills ivars and
    /// OS_UNFAIR_LOCK_INIT is all-zero, so there is nothing to initialise.
    os_unfair_lock _lock;
    /// **The current task, and the identity every delegate callback is checked against.**
    /// A bounced task keeps delivering (its cancellation lands as -999), so "is this the task I care
    /// about right now" is the only safe guard — see `retryDirect`. Read it via `-isCurrentTask:`.
    NSURLSessionDataTask *_task;
    /// The app cancelled us (`stopLoading`). Suppresses every repair path.
    BOOL _stopped;
}

/// The two accessors that must go through `_lock`. `_stopped` only ever goes NO→YES, so reading it
/// separately from the task identity can't observe a rollback.
- (BOOL)isCurrentTask:(NSURLSessionTask *)t {
    os_unfair_lock_lock(&_lock);
    BOOL current = (t == _task);
    os_unfair_lock_unlock(&_lock);
    return current;
}

- (BOOL)isStopped {
    os_unfair_lock_lock(&_lock);
    BOOL stopped = _stopped;
    os_unfair_lock_unlock(&_lock);
    return stopped;
}

+ (BOOL)canInitWithRequest:(NSURLRequest *)r {
    if ([NSURLProtocol propertyForKey:kHandled inRequest:r]) return NO;
    NSString *s = r.URL.scheme.lowercaseString;
    return [s isEqualToString:@"http"] || [s isEqualToString:@"https"];
}
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)r { return r; }

- (void)startLoading {
    self.startedAt = [[NSDate date] timeIntervalSince1970];
    self.respData = [NSMutableData data];
    [self captureRequestBody];

    NSMutableURLRequest *req = [self outboundRequest];

    // Divert *after* the body drain, so an upload the tap made replayable is still eligible while
    // a stream we couldn't drain is not.
    NSURL *target = JacaDivertTargetURL(req);
    if (target != nil) {
        // The desktop routes and captures on the URL the app actually asked for, never on the
        // loopback one. Set the header before the URL so the outbound request is never briefly
        // repointed without it.
        [req setValue:self.request.URL.absoluteString forHTTPHeaderField:kJacaOriginalURLHeader];
        req.URL = target;
        self.diverted = YES;
    }

    self.session = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration
                                                 delegate:self delegateQueue:nil];
    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:req];
    os_unfair_lock_lock(&_lock);
    _task = task;
    os_unfair_lock_unlock(&_lock);
    [task resume];
}

- (void)stopLoading {
    // Take the task out under the lock and hold it in a local: `retryDirect` can be reassigning
    // `_task` on the delegate queue at this exact moment, and cancelling through the ivar would be
    // racing that store's release.
    os_unfair_lock_lock(&_lock);
    _stopped = YES;
    NSURLSessionDataTask *task = _task;
    os_unfair_lock_unlock(&_lock);
    [task cancel];
}

#pragma mark - Request shaping

/// URLSession uploads arrive as `HTTPBodyStream`, not `HTTPBody`. Read it once here so the bytes
/// can be both reported and re-sent.
- (void)captureRequestBody {
    NSURLRequest *original = self.request;
    self.reqBody = original.HTTPBody;
    if (self.reqBody != nil || original.HTTPBodyStream == nil) return;

    NSInputStream *stream = original.HTTPBodyStream;
    [stream open];
    NSMutableData *buf = [NSMutableData data];
    uint8_t tmp[16384];
    // Drained in full on purpose: this is what makes the request replayable, which both the
    // retry-direct bounce and the fail-open retry depend on. Capping *here* would leave a
    // partial body with no stream left to re-read, so the cap belongs on what we report.
    while (stream.hasBytesAvailable) {
        NSInteger n = [stream read:tmp maxLength:sizeof(tmp)];
        if (n <= 0) break;
        [buf appendBytes:tmp length:(NSUInteger)n];
    }
    [stream close];
    self.drainedRequestStream = YES;
    if (buf.length > 0) self.reqBody = buf;
}

/// The request we actually send: marked so our own protocol doesn't re-enter, with the drained
/// body re-supplied as `HTTPBody`. That re-supply is what makes the request **replayable**, which
/// both safety nets (the retry-direct bounce and the fail-open retry) depend on. A body we could
/// not drain keeps its stream, and `JacaIsDivertEligible` then refuses to divert it.
- (NSMutableURLRequest *)outboundRequest {
    NSMutableURLRequest *req = [self.request mutableCopy];
    [NSURLProtocol setProperty:@YES forKey:kHandled inRequest:req];
    // Clearing the stream is gated on having *drained* it, not on having got bytes out of it:
    // a stream that yielded nothing is still open, exhausted and closed, and forwarding it sends
    // a request whose body can never be read.
    if (self.drainedRequestStream || self.reqBody != nil) {
        req.HTTPBodyStream = nil;
        req.HTTPBody = self.reqBody;
    }
    return req;
}

/// Re-sends the app's original request on its own network, abandoning whatever is in flight.
///
/// **`self.task` is reassigned here, and that reassignment is the whole mechanism.** The first
/// version of this used a shared `bouncing` flag, which the retry cleared immediately — so the
/// cancelled task's `didCompleteWithError` arrived afterwards, saw a cleared flag, and failed the
/// app's request with `NSURLErrorCancelled` (-999) even though the retry was succeeding. Task
/// identity can't race: every delegate callback below drops anything that isn't `_task`.
///
/// **Precondition: `stopped`.** A repair is only ever wanted for a request the app still wants.
/// The check lives here rather than at the call sites so it covers both of them (the 599 bounce and
/// the fail-open retry — which makes that branch's own `!self.stopped` harmlessly redundant): a
/// bounce callback already queued on the delegate queue lands *after* `-stopLoading` returns,
/// because `-cancel` is asynchronous, and resuming a new task from it would put the very request
/// the app aborted on the wire and then deliver its completion to a stopped client.
- (void)retryDirect {
    if ([self isStopped]) return;

    self.diverted = NO;
    self.resp = nil;
    self.responseAt = 0;
    [self.respData setLength:0];
    self.respBytes = 0;

    NSMutableURLRequest *req = [self outboundRequest];
    NSURLSessionDataTask *next = [self.session dataTaskWithRequest:req];

    // The check above is a TOCTOU on its own: `-stopLoading` can land between it and the `-resume`,
    // cancel the task it can see (the old one) and return, leaving `next` running for a client that
    // is gone. Publishing `next` as `_task` and re-reading `_stopped` under the *same* lock leaves
    // only two orderings, and neither runs it: either we win the lock and stopLoading then sees
    // `next` and cancels it, or stopLoading won and we see `_stopped` and never resume.
    os_unfair_lock_lock(&_lock);
    BOOL stopped = _stopped;
    if (!stopped) _task = next;
    os_unfair_lock_unlock(&_lock);
    // Not resumed and not published, so it never reaches the network; the cancel is only to hand
    // the task back to the session. The old task stays `_task`, so its cancellation still arrives
    // below and still invalidates the session.
    if (stopped) { [next cancel]; return; }

    [next resume];
}

#pragma mark - NSURLSessionDataDelegate

- (void)URLSession:(NSURLSession *)s dataTask:(NSURLSessionDataTask *)t
 didReceiveResponse:(NSURLResponse *)resp completionHandler:(void (^)(NSURLSessionResponseDisposition))ch {
    if (![self isCurrentTask:t]) { ch(NSURLSessionResponseCancel); return; }
    NSHTTPURLResponse *http = [resp isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)resp : nil;

    // The desktop declined to mock this one. Send it ourselves — and let neither the app nor
    // capture ever see the bounce, so the user gets exactly one row: the real request.
    if (JacaIsRetryDirectBounce(http, self.diverted)) {
        ch(NSURLSessionResponseCancel);
        [self retryDirect];
        return;
    }

    self.resp = http;
    self.responseAt = [[NSDate date] timeIntervalSince1970];
    // A diverted call still has to look like the real URL to the app (cookies, logging, anything
    // reading `response.URL`), so the loopback URL never leaves this file.
    NSURLResponse *forClient = self.diverted ? JacaResponseForClient(http, self.request.URL) : resp;
    [self.client URLProtocol:self didReceiveResponse:(forClient ?: resp)
          cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    ch(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)s dataTask:(NSURLSessionDataTask *)t didReceiveData:(NSData *)d {
    if (![self isCurrentTask:t]) return;
    self.respBytes += d.length;
    // The app always gets every byte below; only what we *report* is capped.
    if (self.respData.length < kJacaBodyRoom) {
        NSUInteger room = kJacaBodyRoom - self.respData.length;
        [self.respData appendData:(d.length <= room ? d : [d subdataWithRange:NSMakeRange(0, room)])];
    }
    [self.client URLProtocol:self didLoadData:d];
}

- (void)URLSession:(NSURLSession *)s task:(NSURLSessionTask *)t didCompleteWithError:(NSError *)error {
    // An abandoned task (the bounced one, cancelled by `retryDirect`) reports here too. Dropping it
    // is what keeps its -999 off the app's request.
    if (![self isCurrentTask:t]) return;

    // Fail open: the tunnel died under us (Jaca quit, port gone). Go read-only and send the app's
    // real request, so the only visible effect is that the override stopped applying. Bounded to
    // one retry, only before anything reached the client, and never for the app's own cancel.
    BOOL appCancelled = [error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled;
    if (error != nil && self.diverted && !self.failedOpen && ![self isStopped]
        && !appCancelled && self.resp == nil) {
        JacaDivertDisarm();
        self.failedOpen = YES;
        [self retryDirect];
        return;
    }

    [self reportTransaction:error];

    // The session retains its delegate (this object) until it's invalidated, so without this every
    // captured request leaks a session and a protocol instance for the life of the app.
    [self.session finishTasksAndInvalidate];

    if (error) { [self.client URLProtocol:self didFailWithError:error]; }
    else { [self.client URLProtocolDidFinishLoading:self]; }
}

#pragma mark - Reporting

/// One `txn` line. Everything is taken from `self.request` — the app's *original* request — so a
/// diverted exchange is still reported as the real https URL, with none of Jaca's own headers.
- (void)reportTransaction:(NSError *)error {
    NSURLRequest *orig = self.request;
    NSTimeInterval finished = [[NSDate date] timeIntervalSince1970];
    NSMutableDictionary *frame = [@{
        @"type": @"txn",
        @"method": orig.HTTPMethod ?: @"GET",
        @"url": orig.URL.absoluteString ?: @"",
        @"startedAt": @(self.startedAt),
        @"finishedAt": @(finished),
        @"requestHeaders": headerDict(orig.allHTTPHeaderFields),
        @"requestSize": @(self.reqBody.length),
        @"responseSize": @(self.respBytes),
        // Tells the desktop which HTTP stack this came from, so it can say whether the row is
        // divertible at all. Everything this protocol sees went through URLSession.
        @"httpStack": @"urlsession",
    } mutableCopy];
    // Binary bodies omit the key rather than fabricating text; the sizes above stay true.
    NSString *requestBody = bodyText(self.reqBody);
    if (requestBody != nil) frame[@"requestBody"] = requestBody;
    NSString *responseBody = bodyText(self.respData);
    if (responseBody != nil) frame[@"responseBody"] = responseBody;

    if (self.responseAt > 0) frame[@"responseAt"] = @(self.responseAt);
    if (self.resp != nil) {
        frame[@"status"] = @(self.resp.statusCode);
        // Carries `X-Jaca-Override` through when a rule answered, which is how the desktop badges
        // the row without matching ids across two id spaces.
        frame[@"responseHeaders"] = headerDict(self.resp.allHeaderFields);
    }
    if (error) frame[@"error"] = error.localizedDescription ?: @"error";
    JacaChannelSendFrame(frame);
}
@end

#pragma mark - Inject our protocol into every URLSession configuration

static NSURLSessionConfiguration *(*orig_def)(id, SEL);
static NSURLSessionConfiguration *(*orig_eph)(id, SEL);
static void addProto(NSURLSessionConfiguration *c) {
    NSMutableArray *p = [c.protocolClasses mutableCopy] ?: [NSMutableArray array];
    [p insertObject:JacaURLProtocol.class atIndex:0];
    c.protocolClasses = p;
}
static NSURLSessionConfiguration *my_def(id s, SEL c) { NSURLSessionConfiguration *x = orig_def(s, c); addProto(x); return x; }
static NSURLSessionConfiguration *my_eph(id s, SEL c) { NSURLSessionConfiguration *x = orig_eph(s, c); addProto(x); return x; }

__attribute__((constructor))
static void jaca_net_init(void) {
    JacaChannelStart();   // dials off the app's launch path; sends the hello on connect

    [NSURLProtocol registerClass:JacaURLProtocol.class];
    Method d = class_getClassMethod(NSURLSessionConfiguration.class, @selector(defaultSessionConfiguration));
    Method e = class_getClassMethod(NSURLSessionConfiguration.class, @selector(ephemeralSessionConfiguration));
    orig_def = (void *)method_getImplementation(d); method_setImplementation(d, (IMP)my_def);
    orig_eph = (void *)method_getImplementation(e); method_setImplementation(e, (IMP)my_eph);
}
