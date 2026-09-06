// JacaNetChannel.m — see JacaNetChannel.h.
//
// Three invariants live here and nowhere else in the agent:
//   * SO_NOSIGPIPE, so a write to a socket Jaca already closed can't kill the *user's app*;
//   * newline framing, with a partial line held over between reads;
//   * EOF ⇒ JacaDivertDisarm(), unconditionally — the dead-man switch that survives a SIGKILL, a
//     Force Quit or a crashed Jaca. (JacaDivert's window covers the half-open case where no EOF
//     ever arrives.)

#import "JacaNetChannel.h"
#import "JacaDivert.h"

#import <arpa/inet.h>
#import <netinet/in.h>
#import <netinet/tcp.h>
#import <sys/socket.h>
#import <unistd.h>

NSString *const kJacaHelloFrame = @"{\"type\":\"hello\",\"stage\":1,\"caps\":[\"override/1\"]}";

/// Only the reader thread ever closes the socket, and only `gQueue` ever touches `gSocket`.
/// A writer that fails calls `shutdown` instead of `close`, which wakes the reader and lets it do
/// the closing — so the fd number can never be recycled underneath a queued write.
static dispatch_queue_t gQueue;
static int gSocket = -1;
/// True once we have connected at least once. The first dial races the app's launch against Jaca
/// binding its listener, so it retries hard; later dials must not, or every transaction reported
/// after Jaca quit would block this queue for two seconds trying to reach a listener that is gone.
static BOOL gEverConnected = NO;

static dispatch_queue_t JacaChannelQueue(void);

#pragma mark - Reading

/// Splits `buffer` on newlines, applies each complete line, and leaves any partial line behind.
static void JacaChannelDrainLines(NSMutableData *buffer) {
    const char *bytes = (const char *)buffer.bytes;
    NSUInteger length = buffer.length, start = 0;
    for (NSUInteger i = 0; i < length; i++) {
        if (bytes[i] != '\n') continue;
        NSUInteger lineLength = i - start;
        if (lineLength > 0) {
            NSString *line = [[NSString alloc] initWithBytes:bytes + start
                                                      length:lineLength
                                                    encoding:NSUTF8StringEncoding];
            // A line that isn't valid UTF-8 is dropped rather than allowed to desync the framing.
            if (line != nil) JacaDivertApplyControlLine(line);
        }
        start = i + 1;
    }
    if (start > 0) [buffer replaceBytesInRange:NSMakeRange(0, start) withBytes:NULL length:0];
}

/// Blocks on one connection until EOF or error, then disarms. Runs off the app's threads.
static void JacaChannelReadUntilEOF(int fd) {
    NSMutableData *buffer = [NSMutableData data];
    uint8_t chunk[4096];
    while (YES) {
        ssize_t n = recv(fd, chunk, sizeof(chunk), 0);
        if (n <= 0) break;
        [buffer appendBytes:chunk length:(NSUInteger)n];
        JacaChannelDrainLines(buffer);
    }
    // Unconditional: normal close, error, or a Jaca that was killed. The app goes back to its own
    // network on its very next request, with nobody having to run any cleanup.
    JacaDivertDisarm();
    dispatch_async(JacaChannelQueue(), ^{
        if (gSocket == fd) gSocket = -1;   // cleared *before* the close, so no queued write can
        close(fd);                         // reach a recycled fd number
    });
}

#pragma mark - Connecting + writing

static void JacaChannelWrite(NSData *payload);

/// Runs on `gQueue`. Leaves `gSocket >= 0` on success.
static void JacaChannelConnect(void) {
    if (gSocket >= 0) return;
    const char *portText = getenv("JACA_NET_PORT");
    if (portText == NULL) return;
    int port = atoi(portText);
    if (port <= 0) return;

    int attempts = gEverConnected ? 1 : 20;   // ~2s on the launch race, then never again
    for (int attempt = 0; attempt < attempts; attempt++) {
        int fd = socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0) return;
        // Without this, writing to a socket Jaca already closed raises SIGPIPE in the *app's*
        // process, and the default disposition kills it. The agent must never be able to do that.
        int on = 1;
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, sizeof(on));

        struct sockaddr_in addr = {0};
        addr.sin_family = AF_INET;
        addr.sin_port = htons((uint16_t)port);
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr);
        if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0) {
            gSocket = fd;
            gEverConnected = YES;
            // The hello goes out before anything else on this connection, and as a literal so the
            // desktop's AgentFrameTests can assert on the exact bytes.
            JacaChannelWrite([kJacaHelloFrame dataUsingEncoding:NSUTF8StringEncoding]);
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                JacaChannelReadUntilEOF(fd);
            });
            return;
        }
        close(fd);
        usleep(100000);   // 100ms; Jaca binds the listener before it launches us
    }
}

/// Runs on `gQueue`.
static void JacaChannelWrite(NSData *payload) {
    if (gSocket < 0 || payload == nil) return;
    NSMutableData *line = [payload mutableCopy];
    [line appendBytes:"\n" length:1];
    const uint8_t *bytes = line.bytes;
    size_t left = line.length;
    while (left > 0) {
        ssize_t n = send(gSocket, bytes, left, 0);
        if (n <= 0) {
            // Wake the reader and let *it* close: that keeps a single owner for the fd, and the
            // reader's EOF path is also what disarms the divert.
            shutdown(gSocket, SHUT_RDWR);
            return;
        }
        bytes += n;
        left -= (size_t)n;
    }
}

/// The queue is created on first use rather than in `JacaChannelStart` alone, so a transaction
/// reported by an unusually early request can't dispatch onto a nil queue.
static dispatch_queue_t JacaChannelQueue(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gQueue = dispatch_queue_create("dev.srsouza.Jaca.netagent", DISPATCH_QUEUE_SERIAL);
    });
    return gQueue;
}

void JacaChannelSendFrame(NSDictionary *frame) {
    dispatch_async(JacaChannelQueue(), ^{
        JacaChannelConnect();
        if (gSocket < 0) return;
        NSData *json = [NSJSONSerialization dataWithJSONObject:frame options:0 error:NULL];
        if (json == nil) return;
        JacaChannelWrite(json);
    });
}

void JacaChannelStart(void) {
    // Off the app's launch path: the dial retries for up to two seconds.
    dispatch_async(JacaChannelQueue(), ^{ JacaChannelConnect(); });
}
