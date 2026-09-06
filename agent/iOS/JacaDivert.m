// JacaDivert.m — see JacaDivert.h for the contract and the review tripwire.
//
// Twin of agent/kotlin/com/squeeze/capture/Divert.kt. Keep the two semantically identical: the
// desktop produces exactly one frame shape (`OverrideEndpoint.divertFrame`) and both agents have
// to mean the same thing by it.

#import "JacaDivert.h"

#import <mach/mach_time.h>
#import <os/lock.h>

NSString *const kJacaOriginalURLHeader = @"X-Jaca-Original-URL";
NSString *const kJacaDivertHeader = @"X-Jaca-Divert";
NSString *const kJacaRetryDirect = @"retry-direct";
const NSInteger kJacaRetryDirectStatus = 599;

#pragma mark - The monotonic clock

/// Milliseconds on a clock that is monotonic **and keeps counting while the device sleeps**.
///
/// `mach_continuous_time` is the only Darwin clock with both properties, and both are load-bearing:
/// a wall clock would let an NTP step or a user changing the date grant an expired window a fresh
/// lease, and `mach_absolute_time` stops while the process is suspended — so an app backgrounded
/// for an hour would wake up believing the desktop had spoken seconds ago and keep diverting to a
/// port nobody is listening on. (This is `SystemClock.elapsedRealtime()` on the Android side.)
static uint64_t JacaMonotonicMillis(void) {
    static mach_timebase_info_data_t timebase;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ mach_timebase_info(&timebase); });
    uint64_t nanos = mach_continuous_time() * timebase.numer / timebase.denom;
    return nanos / 1000000ULL;
}

#pragma mark - State

// Guarded by `gLock` rather than `volatile`: the whole point of the Kotlin twin's "set the fields
// before the origin" ordering is that no request can observe a live origin against a stale window,
// and a lock gives that structurally instead of by careful statement order.
static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;
static NSString *gOrigin = nil;                 // nil ⇒ read-only. The default.
static NSSet<NSString *> *gHosts = nil;         // already lowercased at configure time
static uint64_t gWindowMillis = 15000;
static uint64_t gLastControlAt = 0;

/// Callers hold `gLock`.
static void JacaDivertDisarmLocked(void) {
    gOrigin = nil;
    gHosts = nil;
}

void JacaDivertConfigure(NSString *origin, NSSet<NSString *> *hosts, int heartbeatSeconds) {
    NSMutableSet<NSString *> *lowered = [NSMutableSet setWithCapacity:hosts.count];
    for (NSString *host in hosts) {
        if (![host isKindOfClass:NSString.class] || host.length == 0) continue;
        [lowered addObject:host.lowercaseString];
    }
    // An empty host set can never arm: it would otherwise be one forgotten guard away from meaning
    // "divert everything". The desktop's `OverrideEndpoint` clears origin and hosts together for
    // the same reason, so this is belt-and-braces on a contract both sides already keep.
    BOOL armed = origin.length > 0 && lowered.count > 0;
    os_unfair_lock_lock(&gLock);
    gHosts = armed ? [lowered copy] : nil;
    // Clamped at zero, never at one: a non-positive window means "already expired", which is the
    // fail-safe direction. Letting a negative through would sign-extend into a ~584-million-year
    // window — a malformed frame that can never disarm.
    gWindowMillis = (uint64_t)MAX(0, heartbeatSeconds) * 1000ULL;
    gLastControlAt = JacaMonotonicMillis();
    gOrigin = armed ? [origin copy] : nil;
    os_unfair_lock_unlock(&gLock);
}

void JacaDivertTouch(void) {
    os_unfair_lock_lock(&gLock);
    gLastControlAt = JacaMonotonicMillis();
    os_unfair_lock_unlock(&gLock);
}

void JacaDivertDisarm(void) {
    os_unfair_lock_lock(&gLock);
    JacaDivertDisarmLocked();
    os_unfair_lock_unlock(&gLock);
}

BOOL JacaDivertIsArmed(void) {
    os_unfair_lock_lock(&gLock);
    BOOL armed = gOrigin != nil;
    os_unfair_lock_unlock(&gLock);
    return armed;
}

NSString *JacaDivertTargetFor(NSString *host, NSString *pathAndQuery) {
    if (host.length == 0) return nil;
    NSString *lowered = host.lowercaseString;
    os_unfair_lock_lock(&gLock);
    NSString *origin = gOrigin;
    if (origin == nil) { os_unfair_lock_unlock(&gLock); return nil; }
    // The dead-man switch, evaluated on the match path. Expiry doesn't just decline this request:
    // it disarms, so the app is provably back on its own network even if Jaca never speaks again.
    if (JacaMonotonicMillis() - gLastControlAt > gWindowMillis) {
        JacaDivertDisarmLocked();
        os_unfair_lock_unlock(&gLock);
        return nil;
    }
    BOOL routed = [gHosts containsObject:lowered];
    os_unfair_lock_unlock(&gLock);
    if (!routed) return nil;
    return [origin stringByAppendingString:pathAndQuery ?: @"/"];
}

void JacaDivertApplyControlLine(NSString *line) {
    if (line.length == 0) return;
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (data == nil) return;
    id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (![parsed isKindOfClass:NSDictionary.class]) return;
    NSDictionary *frame = (NSDictionary *)parsed;
    id type = frame[@"type"];
    if (![type isKindOfClass:NSString.class]) return;

    if ([type isEqualToString:@"divert"]) {
        id rawOrigin = frame[@"origin"];
        NSString *origin = [rawOrigin isKindOfClass:NSString.class] ? (NSString *)rawOrigin : nil;
        NSMutableSet<NSString *> *hosts = [NSMutableSet set];
        id rawHosts = frame[@"hosts"];
        if ([rawHosts isKindOfClass:NSArray.class]) {
            for (id host in (NSArray *)rawHosts) {
                if ([host isKindOfClass:NSString.class]) [hosts addObject:(NSString *)host];
            }
        }
        id rawWindow = frame[@"heartbeatSeconds"];
        int window = [rawWindow isKindOfClass:NSNumber.class] ? ((NSNumber *)rawWindow).intValue : 15;
        JacaDivertConfigure(origin, hosts, window);
    } else if ([type isEqualToString:@"ping"]) {
        JacaDivertTouch();
    }
    // else: forward-compatible. A newer desktop can add frames without breaking this agent.
}

#pragma mark - Pure decisions

NSString *JacaPathAndQuery(NSURL *url) {
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if (components != nil) {
        // The percent-encoded accessors, not `path`/`query`: a decoded path would re-encode
        // differently (a literal `%2F` in a segment is not a `/`) and change what the origin sees.
        NSString *path = components.percentEncodedPath;
        if (path.length == 0) path = @"/";
        NSString *query = components.percentEncodedQuery;
        if (query.length > 0) return [NSString stringWithFormat:@"%@?%@", path, query];
        return path;
    }
    // NSURLComponents refuses some URLs NSURL accepts. Fall back to the same string slice the
    // Kotlin twin uses, so an exotic URL degrades to "carried over untouched" rather than to "/".
    NSString *absolute = url.absoluteString ?: @"";
    NSRange schemeEnd = [absolute rangeOfString:@"://"];
    if (schemeEnd.location == NSNotFound) return @"/";
    NSUInteger from = schemeEnd.location + schemeEnd.length;
    NSRange slash = [absolute rangeOfString:@"/"
                                    options:0
                                      range:NSMakeRange(from, absolute.length - from)];
    if (slash.location == NSNotFound) return @"/";
    return [absolute substringFromIndex:slash.location];
}

BOOL JacaIsDivertEligible(NSURLRequest *req) {
    if (req == nil) return NO;
    // A body stream can only be read once, and both safety nets (the retry-direct bounce and the
    // fail-open retry) re-send the request. The tap drains a stream into `HTTPBody` before asking,
    // so an ordinary upload stays eligible; one we couldn't drain does not.
    if (req.HTTPBodyStream != nil) return NO;
    NSString *connection = [req valueForHTTPHeaderField:@"Connection"];
    if (connection != nil &&
        [connection rangeOfString:@"upgrade" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        return NO;   // WebSocket/h2c and friends: not plain HTTP on the other side.
    }
    return YES;
}

NSURL *JacaDivertTargetURL(NSURLRequest *req) {
    if (!JacaDivertIsArmed()) return nil;      // the hot path when read-only: one lock, no parsing
    if (!JacaIsDivertEligible(req)) return nil;
    NSURL *url = req.URL;
    NSString *host = url.host;
    if (host.length == 0) return nil;
    NSString *target = JacaDivertTargetFor(host, JacaPathAndQuery(url));
    if (target == nil) return nil;
    return [NSURL URLWithString:target];
}

BOOL JacaIsRetryDirectBounce(NSHTTPURLResponse *resp, BOOL wasDiverted) {
    // `wasDiverted` first, and it is not optional: a real origin answering 599 with this header on
    // a request we never diverted would otherwise send us round the same request forever.
    if (!wasDiverted || resp == nil) return NO;
    if (resp.statusCode != kJacaRetryDirectStatus) return NO;
    NSString *value = [resp valueForHTTPHeaderField:kJacaDivertHeader];
    return value != nil && [value caseInsensitiveCompare:kJacaRetryDirect] == NSOrderedSame;
}

NSHTTPURLResponse *JacaResponseForClient(NSHTTPURLResponse *resp, NSURL *originalURL) {
    if (resp == nil || originalURL == nil) return resp;
    NSHTTPURLResponse *restored =
        [[NSHTTPURLResponse alloc] initWithURL:originalURL
                                    statusCode:resp.statusCode
                                   HTTPVersion:@"HTTP/1.1"
                                  headerFields:(NSDictionary<NSString *, NSString *> *)resp.allHeaderFields];
    return restored ?: resp;
}
