package com.squeeze.capture

import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream

/** Accumulates one HTTP transaction and emits it as a JSON line to the host. */
class SqueezeTracker(private val url: String) {
    private val id = SqueezeReporter.nextId()
    @Volatile private var method = "GET"
    /** Which HTTP stack produced this transaction ("okhttp3", "okhttp2", "urlconnection").
     *  Capture metadata, not policy: the desktop uses it to tell the user whether a request is
     *  even *divertible* (only okhttp3 is). It cannot be derived from [callStack], which
     *  deliberately strips okhttp/okio frames to show app code. */
    @Volatile private var httpStack: String? = null
    private val startedAtMs = System.currentTimeMillis()
    @Volatile private var responseAtMs = 0L
    @Volatile private var reported = false

    private var requestHeaders: Map<String, List<String>>? = null
    private val requestBody = ByteArrayOutputStream()
    private var statusCode = 0
    private var responseHeaders: Map<String, List<String>>? = null
    private val responseBody = ByteArrayOutputStream()
    private var error: String? = null
    private val callStack: List<String> = captureStack()

    fun setMethod(m: String?) { if (m != null) method = m }
    fun setHttpStack(s: String?) { if (s != null) httpStack = s }
    fun setRequestHeaders(h: Map<String, List<String>>?) { requestHeaders = h }

    fun appendRequestBody(b: ByteArray, off: Int, len: Int) {
        synchronized(requestBody) {
            val room = BODY_CAP - requestBody.size()
            if (room > 0) requestBody.write(b, off, minOf(len, room))
        }
    }

    fun onResponse(code: Int, headers: Map<String, List<String>>?) {
        if (responseAtMs == 0L) responseAtMs = System.currentTimeMillis()
        statusCode = code
        responseHeaders = headers
    }

    fun appendResponseByte(b: Int) {
        synchronized(responseBody) { if (responseBody.size() < BODY_CAP) responseBody.write(b) }
    }

    fun appendResponseBody(b: ByteArray, off: Int, len: Int) {
        synchronized(responseBody) {
            val room = BODY_CAP - responseBody.size()
            if (room > 0) responseBody.write(b, off, minOf(len, room))
        }
    }

    fun setError(e: String?) { error = e }

    /**
     * Permanently suppresses this transaction.
     *
     * Used for exchanges that are Jaca talking to itself rather than traffic the app made — a
     * retry-direct bounce from the desktop, whose real request is re-sent immediately after and
     * reported on its own tracker. Marking it reported (rather than adding a second flag) means
     * a later [report] from the body tee is a no-op too.
     */
    @Synchronized
    fun cancel() { reported = true }

    @Synchronized
    fun report() {
        if (reported) return
        reported = true
        try {
            val o = JSONObject()
            o.put("type", "txn")
            o.put("id", id.toString())
            o.put("method", method)
            httpStack?.let { o.put("httpStack", it) }
            o.put("url", url)
            o.put("startedAt", startedAtMs / 1000.0)
            if (responseAtMs > 0) o.put("responseAt", responseAtMs / 1000.0)
            o.put("finishedAt", System.currentTimeMillis() / 1000.0)
            o.put("status", statusCode)
            error?.let { o.put("error", it) }
            o.put("requestHeaders", headersToJson(requestHeaders))
            o.put("responseHeaders", headersToJson(responseHeaders))
            o.put("requestBody", bodyToString(requestBody))
            o.put("responseBody", bodyToString(responseBody))
            o.put("requestSize", requestBody.size())
            o.put("responseSize", responseBody.size())
            val cs = JSONArray()
            for (s in callStack) cs.put(s)
            o.put("callStack", cs)
            SqueezeReporter.emit(o.toString())
        } catch (t: Throwable) {
            // never let reporting break the app
        }
    }

    private fun headersToJson(headers: Map<String, List<String>>?): JSONObject {
        val obj = JSONObject()
        if (headers == null) return obj
        try {
            for ((k, v) in headers) obj.put(k ?: "", v?.joinToString(", ") ?: "")
        } catch (t: Throwable) {}
        return obj
    }

    private fun bodyToString(body: ByteArrayOutputStream): String {
        val data = synchronized(body) { body.toByteArray() }
        if (data.isEmpty()) return ""
        return try { String(data, Charsets.UTF_8) } catch (e: Exception) { "<${data.size} bytes>" }
    }

    /** App-centric call stack: drop our agent, okhttp/okio, reflection and proxy frames
     *  so the stack starts at the app code that issued the request (like AOSP slices the
     *  okhttp frames off). */
    private fun captureStack(): List<String> {
        val st = Thread.currentThread().stackTrace
        val out = ArrayList<String>()
        for (e in st) {
            if (isInfraFrame(e.className)) continue
            out.add(e.toString())
            if (out.size >= 24) break
        }
        return out
    }

    private fun isInfraFrame(c: String): Boolean =
        c.startsWith("com.squeeze") ||
        c.startsWith("okhttp3.") || c.startsWith("okhttp.") || c.startsWith("com.squareup.okhttp") ||
        c.startsWith("okio.") ||
        c.startsWith("java.lang.reflect.") || c.startsWith("jdk.internal.") ||
        c.startsWith("dalvik.system.") || c.contains("\$Proxy") ||
        c == "java.lang.Thread"

    companion object { private const val BODY_CAP = 1024 * 1024 }
}
