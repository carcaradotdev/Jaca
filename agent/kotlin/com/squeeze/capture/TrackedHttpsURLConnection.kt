package com.squeeze.capture

import java.io.InputStream
import java.io.OutputStream
import java.net.URL
import java.security.Permission
import java.security.Principal
import java.security.cert.Certificate
import javax.net.ssl.HostnameVerifier
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLSocketFactory

/** Delegating HttpsURLConnection that records the request/response via SqueezeTracker. */
class TrackedHttpsURLConnection(
    private val d: HttpsURLConnection,
    private val tracker: SqueezeTracker,
) : HttpsURLConnection(d.url) {

    init { tracker.setHttpStack("urlconnection") }


    private var requestCaptured = false

    private fun captureRequest() {
        if (requestCaptured) return
        requestCaptured = true
        try {
            // HttpURLConnection keeps requestMethod == "GET" until connect even when
            // doOutput is set (which implies POST), so correct it here like AOSP does.
            tracker.setMethod(if (d.doOutput && d.requestMethod == "GET") "POST" else d.requestMethod)
            tracker.setRequestHeaders(d.requestProperties)
        } catch (t: Throwable) {}
    }

    // --- capture points ---
    override fun connect() { captureRequest(); d.connect() }
    override fun getOutputStream(): OutputStream { captureRequest(); return RequestStream(d.outputStream, tracker) }
    override fun getResponseCode(): Int {
        captureRequest()
        val code = d.responseCode
        tracker.onResponse(code, d.headerFields)
        return code
    }
    override fun getInputStream(): InputStream {
        captureRequest()
        return try {
            tracker.onResponse(d.responseCode, d.headerFields)
            ResponseStream(d.inputStream, tracker)
        } catch (e: java.io.IOException) {
            tracker.setError(e.toString()); tracker.report(); throw e
        }
    }
    override fun getErrorStream(): InputStream? {
        val es = d.errorStream ?: return null
        return ResponseStream(es, tracker)
    }
    override fun disconnect() { tracker.report(); d.disconnect() }

    // --- HttpURLConnection / URLConnection delegation ---
    override fun usingProxy(): Boolean = d.usingProxy()
    override fun getResponseMessage(): String? = d.responseMessage
    override fun setRequestMethod(method: String?) { d.requestMethod = method }
    override fun getRequestMethod(): String? = d.requestMethod
    override fun setInstanceFollowRedirects(followRedirects: Boolean) { d.instanceFollowRedirects = followRedirects }
    override fun getInstanceFollowRedirects(): Boolean = d.instanceFollowRedirects
    override fun setFixedLengthStreamingMode(contentLength: Int) { d.setFixedLengthStreamingMode(contentLength) }
    override fun setFixedLengthStreamingMode(contentLength: Long) { d.setFixedLengthStreamingMode(contentLength) }
    override fun setChunkedStreamingMode(chunklen: Int) { d.setChunkedStreamingMode(chunklen) }
    override fun getPermission(): Permission? = d.permission
    override fun getHeaderFieldKey(n: Int): String? = d.getHeaderFieldKey(n)
    override fun getHeaderField(n: Int): String? = d.getHeaderField(n)
    override fun getHeaderField(name: String?): String? = d.getHeaderField(name)
    override fun getHeaderFields(): MutableMap<String, MutableList<String>> = d.headerFields
    override fun getHeaderFieldInt(name: String?, default: Int): Int = d.getHeaderFieldInt(name, default)
    override fun getHeaderFieldDate(name: String?, default: Long): Long = d.getHeaderFieldDate(name, default)
    override fun setConnectTimeout(timeout: Int) { d.connectTimeout = timeout }
    override fun getConnectTimeout(): Int = d.connectTimeout
    override fun setReadTimeout(timeout: Int) { d.readTimeout = timeout }
    override fun getReadTimeout(): Int = d.readTimeout
    override fun getURL(): URL = d.url
    override fun getContentLength(): Int = d.contentLength
    override fun getContentLengthLong(): Long = d.contentLengthLong
    override fun getContentType(): String? = d.contentType
    override fun getContentEncoding(): String? = d.contentEncoding
    override fun getExpiration(): Long = d.expiration
    override fun getDate(): Long = d.date
    override fun getLastModified(): Long = d.lastModified
    override fun getContent(): Any? = d.content
    override fun getContent(classes: Array<out Class<*>>?): Any? = d.getContent(classes)
    override fun setDoInput(doInput: Boolean) { d.doInput = doInput }
    override fun getDoInput(): Boolean = d.doInput
    override fun setDoOutput(doOutput: Boolean) { d.doOutput = doOutput }
    override fun getDoOutput(): Boolean = d.doOutput
    override fun setAllowUserInteraction(v: Boolean) { d.allowUserInteraction = v }
    override fun getAllowUserInteraction(): Boolean = d.allowUserInteraction
    override fun setUseCaches(v: Boolean) { d.useCaches = v }
    override fun getUseCaches(): Boolean = d.useCaches
    override fun setIfModifiedSince(v: Long) { d.ifModifiedSince = v }
    override fun getIfModifiedSince(): Long = d.ifModifiedSince
    override fun setDefaultUseCaches(v: Boolean) { d.defaultUseCaches = v }
    override fun getDefaultUseCaches(): Boolean = d.defaultUseCaches
    override fun setRequestProperty(key: String?, value: String?) { d.setRequestProperty(key, value) }
    override fun addRequestProperty(key: String?, value: String?) { d.addRequestProperty(key, value) }
    override fun getRequestProperty(key: String?): String? = d.getRequestProperty(key)
    override fun getRequestProperties(): MutableMap<String, MutableList<String>> = d.requestProperties

    // --- HttpsURLConnection specifics ---
    override fun getCipherSuite(): String? = d.cipherSuite
    override fun getLocalCertificates(): Array<Certificate>? = d.localCertificates
    override fun getServerCertificates(): Array<Certificate> = d.serverCertificates
    override fun getPeerPrincipal(): Principal = d.peerPrincipal
    override fun getLocalPrincipal(): Principal? = d.localPrincipal
    override fun setHostnameVerifier(v: HostnameVerifier?) { d.hostnameVerifier = v }
    override fun getHostnameVerifier(): HostnameVerifier = d.hostnameVerifier
    override fun setSSLSocketFactory(sf: SSLSocketFactory?) { d.sslSocketFactory = sf }
    override fun getSSLSocketFactory(): SSLSocketFactory = d.sslSocketFactory
}
