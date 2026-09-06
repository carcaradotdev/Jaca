package com.squeeze.capture

/**
 * **EXPERIMENTAL PROOF OF CONCEPT — one hard-coded endpoint.**
 *
 * Proves that the in-process agent can override a response without a proxy, without a CA,
 * and without tripping certificate pinning.
 *
 * The rewrite must run as an **application** interceptor (`OkHttpClient.interceptors()`), not
 * a network one. okhttp enforces two invariants on *network* interceptors: they must call
 * `proceed()` exactly once, and they "must retain the same host and port" — the connection is
 * already established by then, so repointing a request there throws IllegalStateException and
 * takes the app down. Application interceptors run before a connection exists, so changing the
 * host is legal there. Capture stays on the network list, where the real wire data is.
 *
 * Rather than fabricating a response, we repoint the request at a mock server on the desktop:
 *
 *     https://private-api.teya.xyz/lending/v1/...   ->   http://localhost:8099/lending/v1/...
 *
 * reached over `adb reverse tcp:8099 tcp:8099`. Two reasons that's safe here:
 *  - It's **cleartext to `localhost`**, which the app's own `network_security_config.xml`
 *    already permits, so no CA install is needed.
 *  - No TLS handshake happens app-side, so `CertificatePinner` never engages — this works
 *    on pinned endpoints that a MITM proxy (Charles/Proxyman) cannot touch.
 *
 * The rewrite is undone on the way back ([OkHttpHook] restores the original request onto the
 * response), so the app still sees the real URL.
 *
 * Scope is deliberately tiny: one URL, one target, a compile-time [ENABLED] flag. Rules,
 * persistence and UI come later — see the discussion in the network-inspector work. Delete
 * this file and its single call site in [OkHttpHook] to remove the experiment entirely.
 */
internal object PocDivert {

    /** Master switch for the experiment. Flip to `false` to make the agent purely read-only again. */
    const val ENABLED = true

    /** Header carrying the URL the app *meant* to call, so the mock can route on it. */
    const val ORIGINAL_URL_HEADER = "X-Jaca-Original-URL"

    private const val MATCH_ORIGIN = "https://private-api.teya.xyz"
    private const val MATCH_PATH = "/lending/v1/companies/"
    private const val MATCH_ENDPOINT = "/product-state"

    /** Where the desktop mock server is reachable from the device (via `adb reverse`). */
    private const val LOCAL_ORIGIN = "http://localhost:8099"

    /**
     * The mock URL for [url], or null when it isn't the endpoint under test.
     *
     * Matching keeps the company UUID and query string intact (they're just carried over to
     * the mock), so the rule still fires for a different company or locale.
     */
    fun targetFor(url: String): String? {
        if (!ENABLED) return null
        if (!url.startsWith(MATCH_ORIGIN)) return null
        if (!url.contains(MATCH_PATH) || !url.contains(MATCH_ENDPOINT)) return null
        return LOCAL_ORIGIN + url.substring(MATCH_ORIGIN.length)
    }
}
