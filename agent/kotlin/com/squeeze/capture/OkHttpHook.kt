package com.squeeze.capture

import android.util.Log
import com.squeeze.agent.SqueezeHooks
import java.io.ByteArrayOutputStream
import java.lang.reflect.InvocationHandler
import java.lang.reflect.Method
import java.lang.reflect.Modifier
import java.lang.reflect.Proxy
import java.util.zip.GZIPInputStream

/**
 * Injects a capture interceptor into okhttp clients (okhttp3 and okhttp2/squareup).
 * We can't compile against the app's okhttp (it's on the app class loader, not ours),
 * so the capture logic ([Handler]) speaks to okhttp entirely through reflection.
 *
 * Hooked via SqueezeHooks on OkHttpClient.networkInterceptors(): the exit hook returns
 * a list with our interceptor prepended, so it runs for every call.
 *
 * **okhttp3 uses a REAL interceptor class, not a dynamic Proxy.** A `java.lang.reflect.Proxy`
 * re-wraps any thrown checked exception as `UndeclaredThrowableException` unless the proxied
 * method declares it — and R8 strips the `throws IOException` off `okhttp3.Interceptor.intercept`
 * in release/minified apps (it keeps names + line numbers, but not the Exceptions attribute).
 * So a cancelled/failed call's `IOException` came back as an *unchecked* UndeclaredThrowableException,
 * slipped past okhttp's `catch (IOException)` on the async dispatcher, hit `catch (Throwable)`,
 * and crashed the app. A real class is invoked directly (no proxy), so its IOException propagates
 * unchanged. The class ([SqueezeOkHttp3Interceptor], compiled against okhttp stubs and shipped in
 * the capture dex) is loaded on a child loader whose PARENT is the app loader, so it binds to the
 * app's okhttp3 and calls back into this capture logic through the bootstrap [SqueezeOkHttpDelegate]
 * bridge. okhttp2/squareup keeps the Proxy path (legacy; same crash class is far less likely there).
 *
 * Response bodies are captured with a **lazy tee** (a Proxy of okio.Source that copies
 * bytes as the app reads them), NOT an eager peek. Reading ahead on a live HTTP/2 stream
 * can block/time out and reset the stream with CANCEL, which then crashes the app's own
 * read (okhttp3.internal.http2.StreamResetException: stream was reset: CANCEL). The tee
 * never reads ahead, so it can't corrupt the stream; it mirrors how AOSP's network
 * inspector wraps the body instead of peeking it.
 */
object OkHttpHook {
    private const val TAG = "SqueezeAgent"

    private val interceptors = java.util.concurrent.ConcurrentHashMap<String, Any>()
    private val failed = java.util.concurrent.ConcurrentHashMap.newKeySet<String>()
    private val handler = Handler()

    /** Which okhttp interceptor list we're being injected into. The role decides both our
     *  position in the list and what we're allowed to do (see [Handler.intercept]). */
    enum class Role { APPLICATION, NETWORK }

    /** Returns a list containing our interceptor, or the original on any failure.
     *  [ifaceName] is the okhttp Interceptor interface (okhttp3 vs squareup).
     *
     *  **Position matters, and differs by role.**
     *  - [Role.NETWORK] → **prepend**, so capture sees the real wire request/response before any
     *    of the app's own network interceptors can alter them.
     *  - [Role.APPLICATION] → **append**, so we rewrite the URL *after* the app's interceptors
     *    have run. Prepending here would repoint the URL first, and a host-gated auth interceptor
     *    would then silently stop attaching its token (and the app's own logging would show
     *    `localhost`). Appending still leaves us ahead of `RetryAndFollowUpInterceptor`, so
     *    `chain.connection() == null` — and the application-layer invariant — still holds. */
    fun inject(existing: List<*>, ifaceName: String, role: Role = Role.NETWORK): List<*> {
        val ic = ensureInterceptor(ifaceName) ?: return existing
        if (existing.any { it === ic }) return existing
        // okhttp2's networkInterceptors() returns the live mutable list (add in place);
        // okhttp3's is immutable, so fall back to a new list.
        return try {
            @Suppress("UNCHECKED_CAST")
            val live = existing as MutableList<Any?>
            if (role == Role.APPLICATION) live.add(ic) else live.add(0, ic)
            existing
        } catch (t: Throwable) {
            val out = ArrayList<Any?>(existing.size + 1)
            if (role == Role.APPLICATION) { out.addAll(existing); out.add(ic) }
            else { out.add(ic); out.addAll(existing) }
            out
        }
    }

    private fun ensureInterceptor(ifaceName: String): Any? {
        interceptors[ifaceName]?.let { return it }
        if (failed.contains(ifaceName)) return null
        synchronized(this) {
            interceptors[ifaceName]?.let { return it }
            val ic = try {
                if (ifaceName == "okhttp3.Interceptor") buildOkhttp3Interceptor()
                else buildProxyInterceptor(ifaceName)
            } catch (t: Throwable) {
                Log.e(TAG, "$ifaceName interceptor build failed: $t"); null
            }
            if (ic == null) { failed.add(ifaceName); return null }
            interceptors[ifaceName] = ic
            return ic
        }
    }

    /** okhttp3: a real [SqueezeOkHttp3Interceptor] loaded on a child of the app loader (so its
     *  `throws IOException` survives and it binds to the app's okhttp3). Falls back to the Proxy
     *  if the dex/loader isn't available — apps that didn't strip the throws clause work either way. */
    private fun buildOkhttp3Interceptor(): Any? {
        val appLoader = SqueezeHooks.appClassLoader ?: Thread.currentThread().contextClassLoader
        val dexPath = SqueezeHooks.captureDexPath
        if (appLoader != null && dexPath != null) {
            try {
                val dexBytes = java.io.File(dexPath).readBytes()
                val child = dalvik.system.InMemoryDexClassLoader(java.nio.ByteBuffer.wrap(dexBytes), appLoader)
                val cls = child.loadClass("com.squeeze.capture.SqueezeOkHttp3Interceptor")
                val delIface = Class.forName("com.squeeze.agent.SqueezeOkHttpDelegate")
                val ic = cls.getConstructor(delIface).newInstance(CaptureDelegate(handler))
                Log.i(TAG, "okhttp3 capture interceptor installed (real class)")
                return ic
            } catch (t: Throwable) {
                Log.e(TAG, "okhttp3 real-class interceptor failed, falling back to proxy: $t")
            }
        }
        return buildProxyInterceptor("okhttp3.Interceptor")
    }

    /** Fallback / okhttp2 path: a dynamic Proxy of the Interceptor interface. */
    private fun buildProxyInterceptor(ifaceName: String): Any? {
        val loader = SqueezeHooks.appClassLoader ?: Thread.currentThread().contextClassLoader ?: return null
        val interceptorCls = Class.forName(ifaceName, false, loader)
        val proxy = Proxy.newProxyInstance(loader, arrayOf(interceptorCls), handler)
        Log.i(TAG, "$ifaceName capture interceptor installed (proxy)")
        return proxy
    }

    /** Bridges the real okhttp3 interceptor class (app-parented loader) back to the capture
     *  logic here (isolated capture loader). The bootstrap interface is shared by both loaders,
     *  so the call crosses the loader boundary cleanly; a thrown IOException propagates through. */
    private class CaptureDelegate(private val handler: Handler) : com.squeeze.agent.SqueezeOkHttpDelegate {
        @Throws(java.io.IOException::class)
        override fun intercept(chain: Any?): Any? = handler.capture(chain!!)
    }

    private class Handler : InvocationHandler {
        override fun invoke(proxy: Any, method: Method, args: Array<out Any?>?): Any? {
            if (method.name == "intercept" && args != null && args.isNotEmpty() && args[0] != null) {
                return intercept(args[0]!!)
            }
            return when (method.name) {
                "hashCode" -> System.identityHashCode(proxy)
                "equals" -> proxy === args?.getOrNull(0)
                "toString" -> "SqueezeOkHttpInterceptor"
                else -> null
            }
        }

        /** Entry point for the real okhttp3 interceptor class (which can't see this private
         *  member through the Proxy path). Runs the same capture as [invoke]'s intercept branch. */
        @Throws(java.io.IOException::class)
        fun capture(chain: Any): Any = intercept(chain)

        // Mirrors AOSP's OkHttp{3,2}Interceptor: track the request up-front (best-effort),
        // run proceed(), and on failure record the error and RETHROW the real exception
        // so okhttp handles it normally (a cancel/IO error must not crash the app).
        private fun intercept(chain: Any): Any {
            val chainCls = chain.javaClass
            val request = invokeUnwrapped { chainCls.getMethod("request").invoke(chain) }

            // We're injected into BOTH interceptor lists, and the role decides what we do.
            // An APPLICATION interceptor runs before a connection exists (chain.connection()
            // == null); that's the only layer where a request's host/port may change. A
            // NETWORK interceptor runs on an established connection, and okhttp hard-fails
            // a host/port change there ("must retain the same host and port"), so the POC
            // divert must happen on the application side — and capture stays on the network
            // side, where the real wire request/response live.
            if (isApplicationLayer(chainCls, chain)) return divertPass(chainCls, chain, request)

            val tracker = try { startTracker(request) } catch (t: Throwable) { null }

            val response: Any
            try {
                response = invokeUnwrapped { chainCls.getMethod("proceed", request.javaClass).invoke(chain, request) }
            } catch (e: Throwable) {
                try { tracker?.setError(e.toString()); tracker?.report() } catch (ignored: Throwable) {}
                throw e
            }

            // Return the (possibly body-wrapped) response. Never let capture break the call:
            // on any failure fall back to the original response.
            return try {
                if (tracker != null) recordResponse(tracker, response) else response
            } catch (t: Throwable) { response }
        }

        /** Application-interceptor pass: divert a matched request, otherwise stay out of the
         *  way entirely. No capture here — the network-layer pass records the transaction.
         *
         *  Two safety nets make a dead desktop harmless, and neither needs Jaca running:
         *   - **retry-direct**: the desktop bounces anything it isn't mocking with 599, and we
         *     re-run the original request. Calling `proceed()` more than once is legal *here* —
         *     that is exactly how okhttp's own retry interceptors work — but would be illegal
         *     on the network layer.
         *   - **fail-open**: if the tunnel is gone (ECONNREFUSED and friends), disarm and retry
         *     the original once, so a SIGKILLed Jaca can't brick the user's app. */
        private fun divertPass(chainCls: Class<*>, chain: Any, request: Any): Any {
            val outbound = divertIfMatched(request)
            val proceed = chainCls.getMethod("proceed", request.javaClass)
            if (outbound === request) return invokeUnwrapped { proceed.invoke(chain, request) }

            val response = try {
                invokeUnwrapped { proceed.invoke(chain, outbound) }
            } catch (t: Throwable) {
                // The tunnel died under us. Go read-only and let the app's real request through,
                // so the only visible effect is that the override stopped applying.
                Log.e(TAG, "divert: tunnel unreachable, failing open and retrying direct", t)
                Divert.disarm()
                return invokeUnwrapped { proceed.invoke(chain, request) }
            }

            if (isRetryDirect(response)) {
                closeQuietly(response)
                return invokeUnwrapped { proceed.invoke(chain, request) }
            }
            // Put the ORIGINAL request back on the response, so a diverted call still looks
            // like the real URL to the app (cookies, logging, anything reading response.request).
            return restoreRequest(response, request)
        }

        /** True when the desktop declined to mock this request and wants us to send it directly. */
        private fun isRetryDirect(response: Any): Boolean = try {
            val cls = response.javaClass
            val code = cls.getMethod("code").invoke(response) as Int
            code == Divert.RETRY_DIRECT_STATUS &&
                (cls.getMethod("header", String::class.java)
                    .invoke(response, Divert.DIVERT_HEADER) as? String) == Divert.RETRY_DIRECT
        } catch (t: Throwable) {
            false
        }

        /** Releases a bounced response's connection; a leaked body would starve the pool. */
        private fun closeQuietly(response: Any) {
            try { response.javaClass.getMethod("close").invoke(response) } catch (t: Throwable) {
                try {
                    val body = response.javaClass.getMethod("body").invoke(response)
                    body?.javaClass?.getMethod("close")?.invoke(body)
                } catch (ignored: Throwable) {}
            }
        }

        /** True when this chain is an application interceptor (no connection yet). Defaults to
         *  false — if we can't tell, behave as the network layer and never rewrite the URL. */
        private fun isApplicationLayer(chainCls: Class<*>, chain: Any): Boolean = try {
            chainCls.getMethod("connection").invoke(chain) == null
        } catch (t: Throwable) {
            false
        }

        /** A copy of [request] pointed at the desktop when [Divert] says this host is routed,
         *  otherwise [request] itself. okhttp3 only — okhttp2 keeps the plain capture path.
         *  Any failure returns the original request unchanged. */
        private fun divertIfMatched(request: Any): Any {
            if (!Divert.isArmed) return request
            return try {
                val reqCls = request.javaClass
                if (reqCls.name != "okhttp3.Request") return request
                if (!isDivertEligible(request, reqCls)) return request
                val httpUrl = reqCls.getMethod("url").invoke(request)
                val url = httpUrl.toString()
                val host = (httpUrl.javaClass.getMethod("host").invoke(httpUrl) as? String)
                    ?.lowercase() ?: return request
                val target = Divert.targetFor(host, pathAndQuery(url)) ?: return request
                val builder = reqCls.getMethod("newBuilder").invoke(request)
                val bCls = builder.javaClass
                bCls.getMethod("url", String::class.java).invoke(builder, target)
                bCls.getMethod("header", String::class.java, String::class.java)
                    .invoke(builder, Divert.ORIGINAL_URL_HEADER, url)
                val diverted = invokeUnwrapped { bCls.getMethod("build").invoke(builder) }
                Log.i(TAG, "divert: $url -> $target")
                diverted
            } catch (t: Throwable) {
                Log.e(TAG, "divert failed; proceeding with the original request", t)
                request
            }
        }

        /** Everything after the origin — the desktop reconstructs the real URL from the header,
         *  so the path/query only has to survive the hop intact. */
        private fun pathAndQuery(url: String): String {
            val schemeEnd = url.indexOf("://")
            if (schemeEnd < 0) return "/"
            val slash = url.indexOf('/', schemeEnd + 3)
            return if (slash < 0) "/" else url.substring(slash)
        }

        /** Requests that must never be diverted, because the retry-direct bounce (or a fail-open
         *  retry) would have to re-send a body that can only be sent once, or would break a
         *  protocol upgrade that isn't plain HTTP on the other side. */
        private fun isDivertEligible(request: Any, reqCls: Class<*>): Boolean {
            try {
                val body = reqCls.getMethod("body").invoke(request)
                if (body != null && (boolMethod(body, "isOneShot") || boolMethod(body, "isDuplex"))) return false
                val upgrade = reqCls.getMethod("header", String::class.java)
                    .invoke(request, "Connection") as? String
                if (upgrade != null && upgrade.contains("upgrade", ignoreCase = true)) return false
            } catch (t: Throwable) {
                return false   // can't prove it's safe → leave it alone
            }
            return true
        }

        /** The [Divert.ORIGINAL_URL_HEADER] value, or null when this request wasn't diverted. */
        private fun originalUrlHeader(request: Any, reqCls: Class<*>): String? = try {
            reqCls.getMethod("header", String::class.java)
                .invoke(request, Divert.ORIGINAL_URL_HEADER) as? String
        } catch (t: Throwable) {
            null
        }

        /** Rebuilds [response] carrying [original] as its request, hiding the divert from the app. */
        private fun restoreRequest(response: Any, original: Any): Any {
            return try {
                val rb = response.javaClass.getMethod("newBuilder").invoke(response)
                rb.javaClass.getMethod("request", original.javaClass).invoke(rb, original)
                invokeUnwrapped { rb.javaClass.getMethod("build").invoke(rb) }
            } catch (t: Throwable) {
                Log.e(TAG, "POC divert: couldn't restore the original request", t)
                response
            }
        }

        /** Runs a reflective call, rethrowing the real exception instead of the
         *  InvocationTargetException wrapper that Method.invoke would otherwise leak. */
        private inline fun invokeUnwrapped(block: () -> Any?): Any {
            try {
                return block()!!
            } catch (e: java.lang.reflect.InvocationTargetException) {
                throw e.targetException ?: e
            }
        }

        /** Records the request (method/url/headers/body) and returns the tracker, so the
         *  transaction is emitted even if the call later fails/cancels. */
        private fun startTracker(request: Any): SqueezeTracker {
            val reqCls = request.javaClass
            // A diverted request carries the URL the app actually asked for, so the captured
            // transaction still reads as the real endpoint rather than the local mock.
            val url = originalUrlHeader(request, reqCls)
                ?: reqCls.getMethod("url").invoke(request).toString()
            val tracker = SqueezeTracker(url)
            // Records which stack this came from, so the desktop can say whether the request is
            // divertible at all — only okhttp3 requests can be repointed.
            tracker.setHttpStack(if (reqCls.name.startsWith("okhttp3.")) "okhttp3" else "okhttp2")
            (reqCls.getMethod("method").invoke(request) as? String)?.let { tracker.setMethod(it) }
            tracker.setRequestHeaders(headers(reqCls.getMethod("headers").invoke(request)))
            captureRequestBody(request, tracker)
            return tracker
        }

        /** Capture the request body by writing it into a fresh okio Buffer — exactly what
         *  AOSP does (write the RequestBody to a sink). We only do this for a known,
         *  bounded length and never for one-shot/duplex bodies, so we can't consume a
         *  body the app still needs to send. */
        private fun captureRequestBody(request: Any, tracker: SqueezeTracker) {
            try {
                val body = request.javaClass.getMethod("body").invoke(request) ?: return
                if (boolMethod(body, "isDuplex") || boolMethod(body, "isOneShot")) return
                val len = longMethod(body, "contentLength")
                if (len !in 1..BODY_PEEK) return   // skip empty / unknown / oversized
                val writeTo = body.javaClass.methods.firstOrNull {
                    it.name == "writeTo" && it.parameterTypes.size == 1
                } ?: return
                // The single param is okio.BufferedSink; the concrete Buffer that implements
                // it lives next to it (okio.Buffer, or okhttp2's repackaged equivalent).
                val sinkType = writeTo.parameterTypes[0]
                val bufferCls = Class.forName(sinkType.name.replace("BufferedSink", "Buffer"),
                                              false, sinkType.classLoader)
                val buffer = bufferCls.getConstructor().newInstance()
                writeTo.invoke(body, buffer)
                val bytes = bufferCls.getMethod("readByteArray").invoke(buffer) as ByteArray
                tracker.appendRequestBody(bytes, 0, bytes.size)
            } catch (t: Throwable) { /* request body is best-effort */ }
        }

        /** Records status/headers, then (for okhttp3 non-streaming responses) returns a
         *  response whose body is tee'd through [ResponseBodyTee] so we capture bytes as
         *  the app reads them. Streaming content types and okhttp2 — or any reflection
         *  failure — report headers immediately with no body rather than touch the live
         *  stream. Returns the response the chain should hand back to the app. */
        private fun recordResponse(tracker: SqueezeTracker, response: Any): Any {
            val respCls = response.javaClass
            val code = respCls.getMethod("code").invoke(response) as Int
            val respHeaders = headers(respCls.getMethod("headers").invoke(response))

            // A retry-direct bounce is Jaca talking to itself, not traffic the app made. Drop it
            // so the direct retry that follows is the only row the user sees.
            if (code == Divert.RETRY_DIRECT_STATUS &&
                header(respHeaders, Divert.DIVERT_HEADER) == Divert.RETRY_DIRECT) {
                tracker.cancel()
                return response
            }

            tracker.onResponse(code, respHeaders)

            // peeking/teeing a never-ending body (SSE/gRPC/long-poll) would only emit the
            // txn when the stream finally ends, so report those up-front with no body.
            if (isStreaming(respHeaders)) {
                tracker.report()
                return response
            }

            val wrapped = try {
                ResponseBodyTee.install(response, tracker, respHeaders)
            } catch (t: Throwable) { null }

            if (wrapped == null) tracker.report()   // couldn't tee — emit headers only
            return wrapped ?: response
        }

        private fun boolMethod(obj: Any, name: String): Boolean = try {
            obj.javaClass.getMethod(name).invoke(obj) as? Boolean ?: false
        } catch (t: Throwable) { false }

        private fun longMethod(obj: Any, name: String): Long = try {
            (obj.javaClass.getMethod(name).invoke(obj) as? Long) ?: -1L
        } catch (t: Throwable) { -1L }

        @Suppress("UNCHECKED_CAST")
        private fun headers(headers: Any?): Map<String, List<String>>? {
            headers ?: return null
            return try {
                headers.javaClass.getMethod("toMultimap").invoke(headers) as? Map<String, List<String>>
            } catch (t: Throwable) { null }
        }

        /** Content types that never end (or shouldn't be eagerly buffered) — teeing
         *  these would defer the txn until the stream finally closes. */
        private fun isStreaming(headers: Map<String, List<String>>?): Boolean {
            val ct = header(headers, "Content-Type")?.lowercase() ?: return false
            return ct.startsWith("text/event-stream") ||
                ct.startsWith("application/grpc") ||
                ct.contains("x-mixed-replace")
        }

        private fun header(headers: Map<String, List<String>>?, name: String): String? =
            headers?.entries?.firstOrNull { it.key.equals(name, true) }?.value?.firstOrNull()
    }

    private const val BODY_PEEK = 1024L * 1024   // cap captured bodies at 1 MB
}

/**
 * Wraps an okhttp3 Response so its body is read through a tee: every byte the app reads is
 * also copied (up to 1 MB) into the tracker, and the transaction is reported when the body
 * reaches EOF or is closed. Nothing is ever read ahead of the app, so the live HTTP/2 stream
 * is never advanced/blocked/reset by us. Built entirely by reflection (we can't compile
 * against the app's okhttp/okio); any failure returns null and the caller reports headers only.
 */
private object ResponseBodyTee {
    private const val CAP = 1024 * 1024   // cap captured response body at 1 MB (raw, pre-gunzip)

    /** Returns a new Response with a tee'd body, or null if it couldn't be built. */
    fun install(response: Any, tracker: SqueezeTracker, respHeaders: Map<String, List<String>>?): Any? {
        val respCls = response.javaClass
        // okhttp2 has no compatible ResponseBody.create(...,BufferedSource); skip its body.
        if (!respCls.name.startsWith("okhttp3.")) return null
        val loader = respCls.classLoader ?: return null

        val responseBodyBase = Class.forName("okhttp3.ResponseBody", false, loader)
        val body = respCls.getMethod("body").invoke(response) ?: return null
        val source = responseBodyBase.getMethod("source").invoke(body) ?: return null   // okio.BufferedSource
        val contentType = responseBodyBase.getMethod("contentType").invoke(body)        // okhttp3.MediaType?
        val contentLength = responseBodyBase.getMethod("contentLength").invoke(body) as Long

        val okioSourceCls = Class.forName("okio.Source", false, loader)
        val okioBufferCls = Class.forName("okio.Buffer", false, loader)

        val tee = Proxy.newProxyInstance(
            loader, arrayOf(okioSourceCls),
            TeeSource(source, tracker, respHeaders, okioSourceCls, okioBufferCls)
        )
        val buffered = bufferSource(tee, okioSourceCls, loader) ?: return null
        val newBody = createResponseBody(responseBodyBase, contentType, contentLength, buffered, loader)
            ?: return null

        val builder = respCls.getMethod("newBuilder").invoke(response)
        builder.javaClass.getMethod("body", responseBodyBase).invoke(builder, newBody)
        return builder.javaClass.getMethod("build").invoke(builder)
    }

    /** Wrap an okio.Source into a BufferedSource. Okio.buffer(Source) across versions, or the
     *  RealBufferedSource(Source) constructor as a fallback (present in every okio version). */
    private fun bufferSource(src: Any, okioSourceCls: Class<*>, loader: ClassLoader): Any? {
        try {
            val okio = Class.forName("okio.Okio", false, loader)
            return okio.getMethod("buffer", okioSourceCls).invoke(null, src)
        } catch (t: Throwable) { /* fall through */ }
        try {
            val rbs = Class.forName("okio.RealBufferedSource", false, loader)
            val ctor = rbs.getDeclaredConstructor(okioSourceCls)
            ctor.isAccessible = true
            return ctor.newInstance(src)
        } catch (t: Throwable) { return null }
    }

    /** Find a static ResponseBody.create(...) with a (BufferedSource, contentType, long) shape in
     *  any argument order — okhttp3 3.x is (MediaType,long,BufferedSource), 4.x/5.x reorders it. */
    private fun createResponseBody(
        base: Class<*>, contentType: Any?, contentLength: Long, buffered: Any, loader: ClassLoader
    ): Any? {
        val bufferedSourceCls = Class.forName("okio.BufferedSource", false, loader)
        val candidates = base.methods.filter { m ->
            Modifier.isStatic(m.modifiers) && m.name == "create" && m.parameterTypes.size == 3 &&
                m.parameterTypes.any { it.isAssignableFrom(buffered.javaClass) || it == bufferedSourceCls } &&
                m.parameterTypes.any { it == java.lang.Long.TYPE }
        }
        for (m in candidates) {
            try {
                val args = arrayOfNulls<Any?>(3)
                m.parameterTypes.forEachIndexed { i, p ->
                    args[i] = when {
                        p == java.lang.Long.TYPE -> contentLength
                        p.isAssignableFrom(buffered.javaClass) || p == bufferedSourceCls -> buffered
                        else -> contentType   // MediaType? — nullable, so a null contentType is fine
                    }
                }
                return m.invoke(null, *args)
            } catch (t: Throwable) { /* try the next overload */ }
        }
        return null
    }

    /** InvocationHandler for the okio.Source proxy. Delegates read/timeout/close to the real
     *  source and copies the just-read bytes into the tracker (non-destructively) up to the cap. */
    private class TeeSource(
        private val delegate: Any,
        private val tracker: SqueezeTracker,
        private val respHeaders: Map<String, List<String>>?,
        okioSourceCls: Class<*>,
        private val bufferCls: Class<*>
    ) : InvocationHandler {
        private val readMethod = okioSourceCls.getMethod("read", bufferCls, java.lang.Long.TYPE)
        private val timeoutMethod = okioSourceCls.getMethod("timeout")
        private val closeMethod = okioSourceCls.getMethod("close")
        private val copyToMethod = bufferCls.getMethod(
            "copyTo", bufferCls, java.lang.Long.TYPE, java.lang.Long.TYPE
        )
        private val readByteArrayMethod = bufferCls.getMethod("readByteArray")
        // okio 1.x exposes size(); 2.x/3.x exposes the Kotlin property getter getSize().
        private val sizeMethod = try { bufferCls.getMethod("size") } catch (t: Throwable) { bufferCls.getMethod("getSize") }
        private val scratch = bufferCls.getConstructor().newInstance()

        private val captured = ByteArrayOutputStream()
        private var capturedEnough = false
        @Volatile private var finished = false

        override fun invoke(proxy: Any, method: Method, args: Array<out Any?>?): Any? {
            return when (method.name) {
                "read" -> doRead(args!![0]!!, args[1] as Long)
                "close" -> { try { unwrapped { closeMethod.invoke(delegate) } } finally { finish() }; null }
                "timeout" -> timeoutMethod.invoke(delegate)
                "hashCode" -> System.identityHashCode(proxy)
                "equals" -> proxy === args?.getOrNull(0)
                "toString" -> "SqueezeTeeSource"
                else -> null
            }
        }

        private fun doRead(sink: Any, byteCount: Long): Long {
            // Unwrap InvocationTargetException so the delegate's real IOException (e.g. a
            // StreamResetException: CANCEL) propagates unchanged. Leaking the reflection
            // wrapper would surface as UndeclaredThrowableException and crash the app's
            // read — the same trap invokeUnwrapped() guards on the proceed() path.
            val n: Long
            try {
                n = unwrapped { readMethod.invoke(delegate, sink, byteCount) } as Long
            } catch (t: Throwable) {
                finish()       // stream broke mid-read — still emit what we captured
                throw t
            }
            if (n > 0L) { try { capture(sink, n) } catch (t: Throwable) { /* never affect the read */ } }
            else if (n < 0L) finish()   // EOF
            return n
        }

        private inline fun unwrapped(block: () -> Any?): Any? {
            try {
                return block()
            } catch (e: java.lang.reflect.InvocationTargetException) {
                throw e.targetException ?: e
            }
        }

        /** Copy the n bytes just appended to [sink] (at its tail) without consuming them. */
        private fun capture(sink: Any, n: Long) {
            synchronized(captured) {
                if (capturedEnough) return
                val size = sizeMethod.invoke(sink) as Long
                copyToMethod.invoke(sink, scratch, size - n, n)             // copyTo(out, offset, byteCount)
                val chunk = readByteArrayMethod.invoke(scratch) as ByteArray // drains scratch, leaving it empty
                val room = CAP - captured.size()
                if (room > 0) captured.write(chunk, 0, minOf(chunk.size, room))
                if (captured.size() >= CAP) capturedEnough = true
            }
        }

        private fun finish() {
            synchronized(captured) {
                if (finished) return
                finished = true
                try {
                    var bytes = captured.toByteArray()
                    if (isGzip(respHeaders)) bytes = gunzip(bytes)
                    if (bytes.isNotEmpty()) tracker.appendResponseBody(bytes, 0, bytes.size)
                } catch (t: Throwable) { /* body is best-effort */ }
            }
            tracker.report()
        }
    }

    private fun isGzip(headers: Map<String, List<String>>?): Boolean {
        val v = headers?.entries?.firstOrNull { it.key.equals("Content-Encoding", true) }?.value
        return v?.any { it.contains("gzip", true) } == true
    }

    private fun gunzip(data: ByteArray): ByteArray = try {
        GZIPInputStream(data.inputStream()).readBytes()
    } catch (t: Throwable) { data }  // truncated/partial capture — keep what we have
}
