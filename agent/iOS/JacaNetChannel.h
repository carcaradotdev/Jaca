// JacaNetChannel.h — the one TCP connection back to Jaca. Transport only: it frames lines, it
// does not know what a divert is.
//
// The simulator shares the Mac's loopback, so the agent *dials* 127.0.0.1:$JACA_NET_PORT (Jaca
// binds the listener before it launches the app). One socket carries both directions — transaction
// frames out, control frames in — exactly like the Android agent's single localabstract socket.
// That is deliberate: a second socket would need a second port, a second lifetime and a second way
// to go wrong, and this one is already bidirectional for free.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The greeting, sent on every (re)connect. `caps` is what makes the desktop willing to speak at
/// all: it only pushes control frames to an agent that advertised `override/1`, so an older build
/// that never reads its socket is simply never spoken to.
///
/// Kept verbatim in sync with `AgentFrame.classify` (Sources/Core/Network/AgentFrame.swift) and
/// with the Android literal in `SqueezeReporter.kt`.
extern NSString *const kJacaHelloFrame;

/// Starts dialling on a private serial queue. Safe to call once, from the injected constructor.
void JacaChannelStart(void);

/// Writes one newline-delimited JSON frame. Connects on demand if the socket isn't up yet, so a
/// transaction that happens before Jaca is reachable simply retries the dial.
void JacaChannelSendFrame(NSDictionary *frame);

NS_ASSUME_NONNULL_END
