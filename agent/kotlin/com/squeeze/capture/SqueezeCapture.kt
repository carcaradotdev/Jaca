package com.squeeze.capture

import android.util.Log
import com.squeeze.agent.SqueezeExitHandler
import java.net.HttpURLConnection
import javax.net.ssl.HttpsURLConnection

/**
 * Kotlin capture handler, loaded on an isolated class loader (its own bundled
 * Kotlin stdlib, so it never shadows the host app's). Implements the bootstrap
 * Java bridge interface; [onExit] wraps connections returned by hooked methods.
 */
class SqueezeCapture : SqueezeExitHandler {

    fun start(socketName: String?) {
        val name = if (socketName.isNullOrEmpty()) "squeeze_agent" else socketName
        Log.i(TAG, "Kotlin capture start; socket=localabstract:$name")
        SqueezeReporter.listen(name)
    }

    override fun onExit(methodSignature: String?, returnObject: Any?): Any? {
        try {
            if (returnObject is TrackedHttpsURLConnection || returnObject is TrackedHttpURLConnection) return returnObject
            // HttpsURLConnection is a subclass of HttpURLConnection, so check it first.
            if (returnObject is HttpsURLConnection) {
                return TrackedHttpsURLConnection(returnObject, SqueezeTracker(returnObject.url.toString()))
            }
            if (returnObject is HttpURLConnection) {   // cleartext http://
                return TrackedHttpURLConnection(returnObject, SqueezeTracker(returnObject.url.toString()))
            }
            // OkHttpClient.networkInterceptors() → inject our interceptor. The method
            // signature carries the declaring class, so route okhttp2 vs okhttp3.
            if (returnObject is List<*> && methodSignature?.contains("networkInterceptors") == true) {
                val iface = if (methodSignature.contains("squareup")) "com.squareup.okhttp.Interceptor"
                            else "okhttp3.Interceptor"
                return OkHttpHook.inject(returnObject, iface, OkHttpHook.Role.NETWORK)
            }
            // OkHttpClient.interceptors() → the APPLICATION list. Matching is case-sensitive,
            // so this can't collide with "networkInterceptors" (capital I). Same interceptor
            // object; it detects the layer from chain.connection() and only rewrites here.
            // Injected LAST on this list so the app's own interceptors (auth, headers) run
            // against the real URL before we repoint it — see OkHttpHook.inject.
            if (returnObject is List<*> && methodSignature?.contains("interceptors") == true) {
                return OkHttpHook.inject(returnObject, "okhttp3.Interceptor", OkHttpHook.Role.APPLICATION)
            }
        } catch (t: Throwable) {
            Log.e(TAG, "onExit wrap error", t)
        }
        return returnObject
    }

    companion object { const val TAG = "SqueezeAgent" }
}
