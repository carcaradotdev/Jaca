package com.squeeze.capture

import android.os.SystemClock

/**
 * The **entire** on-device response-override surface: a target origin, a set of hostnames, and a
 * heartbeat window.
 *
 * There are deliberately **no patterns, no payloads, no status codes, no ordering, and nothing
 * persisted** here. Rules live on the desktop; this object is a *routing hint*. The device cannot
 * express "mock this path", "return 404", "delay 2s" or "rule #3 wins" — it can only answer
 * "should this host go through the Mac?". [targetFor] is one hash-set membership test.
 *
 * **The tripwire for review:** any change that adds a path, method, header, body, status, ordering
 * or rule-id concept to this file has crossed the line that keeps the agent dumb. The desktop-side
 * `OverrideEndpoint` (Sources/Core/Intercept/Intercept.swift) is the single type where such a
 * change would show up in a diff — it is the only producer of the frame this object consumes.
 * The cross-language contract both sides implement is written down in `docs/divert-contract.md`.
 *
 * [origin] starts `null`, so a freshly attached agent is **read-only by construction**, not by a
 * compile-time flag. (Its predecessor, `PocDivert`, shipped with `ENABLED = true` hard-coded — a
 * rebuild silently diverted a hard-coded endpoint. That is why this default matters.)
 *
 * ### The dead-man switch
 * Expiry is checked on the *match path* rather than by a timer thread, so Doze, a suspended
 * process, or a half-open socket can never starve it: if the desktop hasn't spoken within
 * [windowMs], the next request disarms and goes direct. Together with the EOF disarm in
 * [SqueezeReporter] and the fail-open retry in [OkHttpHook], a SIGKILLed Jaca cannot leave the
 * user's app pointed at a dead tunnel.
 */
internal object Divert {

    /** Carries the URL the app *meant* to call, so the desktop can route and capture on it. */
    const val ORIGINAL_URL_HEADER = "X-Jaca-Original-URL"

    /** Response header the desktop sets to bounce a request back for a direct retry. */
    const val DIVERT_HEADER = "X-Jaca-Divert"

    /** Value of [DIVERT_HEADER] meaning "I'm not mocking this — send it yourself". */
    const val RETRY_DIRECT = "retry-direct"

    /** Status paired with [RETRY_DIRECT]. 599 is unassigned, so it can't collide with an origin. */
    const val RETRY_DIRECT_STATUS = 599

    /** Where the desktop is reachable from the device, or null for **read-only** (the default). */
    @Volatile private var origin: String? = null

    /** Hosts the desktop asked us to route. Everything else stays on the device's own network. */
    @Volatile private var hosts: Set<String> = emptySet()

    /** How long we keep diverting without hearing from the desktop. */
    @Volatile private var windowMs: Long = 15_000L

    @Volatile private var lastControlAt: Long = 0L

    /** Applies a desktop control frame. A null [origin] disarms. */
    fun configure(origin: String?, hosts: Set<String>, heartbeatSeconds: Int) {
        this.hosts = hosts
        this.windowMs = heartbeatSeconds.toLong() * 1000L
        this.lastControlAt = SystemClock.elapsedRealtime()
        this.origin = origin
    }

    /** Keeps the dead-man switch fed; called for every control frame the desktop sends. */
    fun touch() {
        lastControlAt = SystemClock.elapsedRealtime()
    }

    /** Goes read-only. Called on socket EOF, on an explicit disarm, and on a refused connection. */
    fun disarm() {
        origin = null
        hosts = emptySet()
    }

    /** True while we'd divert at all — used to skip work on the hot path when read-only. */
    val isArmed: Boolean get() = origin != null

    /**
     * The URL to send this request to instead, or null to leave it completely alone.
     *
     * @param host the request's host, compared case-insensitively by the caller
     * @param pathAndQuery everything after the origin, carried over untouched
     */
    fun targetFor(host: String, pathAndQuery: String): String? {
        val o = origin ?: return null
        if (SystemClock.elapsedRealtime() - lastControlAt > windowMs) {
            disarm()
            return null
        }
        if (host !in hosts) return null
        return o + pathAndQuery
    }
}
