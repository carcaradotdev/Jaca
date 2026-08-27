package com.squeeze.capture

import android.net.LocalServerSocket
import android.net.LocalSocket
import android.util.Log
import android.os.Process
import org.json.JSONObject
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.OutputStream
import java.util.concurrent.atomic.AtomicLong

/**
 * Owns the localabstract socket to the host: emits one JSON line per transaction, and reads
 * control frames back.
 *
 * The socket has always been physically bidirectional — `accept()` yields a [LocalSocket] with
 * both streams — but only `outputStream` was ever used. Reading `inputStream` gives the desktop a
 * control channel **for free**: no change to the attach spec, no new port, and no compatibility
 * break. That matters because `SqueezeAgent.attach()` early-returns once capture is loaded, so
 * anything carried in the attach spec is frozen for the process lifetime and would need an
 * `am force-stop` to change. Control frames take effect on the next request instead.
 *
 * The hello frame advertises [CAPS] so the desktop only sends frames an agent understands; an
 * older build simply never reads, and the write is harmlessly buffered/dropped.
 */
object SqueezeReporter {
    private const val TAG = "SqueezeAgent"

    /** Capabilities advertised in the hello frame. Bump when the control vocabulary changes. */
    private const val CAPS = "\"override/1\""

    private val seq = AtomicLong(0)
    private val lock = Any()
    @Volatile private var out: OutputStream? = null
    @Volatile private var server: LocalServerSocket? = null
    @Volatile private var client: LocalSocket? = null

    fun nextId(): Long = seq.incrementAndGet()

    fun listen(socketName: String) {
        try { server?.close() } catch (_: Exception) {}  // unblock any prior serve loop
        Thread({ serve(socketName) }, "squeeze-reporter").apply { isDaemon = true; start() }
    }

    private fun serve(socketName: String) {
        try {
            val srv = LocalServerSocket(socketName)
            server = srv
            Log.i(TAG, "reporter listening on localabstract:$socketName")
            while (true) {
                val c = srv.accept()
                // Close the previous client before replacing it: the host reconnects every 0.3s
                // on failure, so leaking one fd per reconnect could exhaust the app's table.
                synchronized(lock) {
                    try { client?.close() } catch (_: Exception) {}
                    client = c
                    out = c.outputStream
                }
                emit("{\"type\":\"hello\",\"pid\":${Process.myPid()},\"stage\":4,\"caps\":[$CAPS]}")
                Log.i(TAG, "host connected")
                startControlReader(c)
            }
        } catch (e: Exception) {
            Log.e(TAG, "reporter error", e)
        }
    }

    /**
     * Reads newline-delimited control frames from the host until EOF.
     *
     * **EOF disarms the divert.** This is the dead-man switch that survives a `SIGKILL`, a Force
     * Quit, or a crashed Jaca: the socket closes, we go read-only, and the app's traffic returns
     * to its own network without anyone having to run cleanup. [Divert] additionally expires on
     * a heartbeat window, which covers a *half-open* socket where no EOF ever arrives.
     */
    private fun startControlReader(socket: LocalSocket) {
        Thread({
            try {
                val reader = BufferedReader(InputStreamReader(socket.inputStream, Charsets.UTF_8))
                while (true) {
                    val line = reader.readLine() ?: break
                    if (line.isNotBlank()) handleControl(line)
                }
            } catch (e: Exception) {
                Log.i(TAG, "control reader ended: $e")
            } finally {
                Divert.disarm()
                Log.i(TAG, "host disconnected — divert disarmed")
            }
        }, "squeeze-control").apply { isDaemon = true; start() }
    }

    /** Applies one control frame. Unknown types are ignored, so the desktop can add frames
     *  without breaking an older agent. */
    private fun handleControl(line: String) {
        try {
            val o = JSONObject(line)
            when (o.optString("type")) {
                "divert" -> {
                    val origin = if (o.isNull("origin")) null else o.optString("origin", null)
                    val arr = o.optJSONArray("hosts")
                    val hosts = HashSet<String>()
                    if (arr != null) for (i in 0 until arr.length()) {
                        arr.optString(i)?.lowercase()?.takeIf { it.isNotEmpty() }?.let { hosts.add(it) }
                    }
                    Divert.configure(origin, hosts, o.optInt("heartbeatSeconds", 15))
                    Log.i(TAG, "divert configured: origin=$origin hosts=$hosts")
                }
                "ping" -> Divert.touch()
                else -> { /* forward-compatible: ignore */ }
            }
        } catch (t: Throwable) {
            Log.e(TAG, "bad control frame", t)
        }
    }

    fun emit(json: String) {
        val o = out ?: return
        try {
            synchronized(lock) {
                o.write((json + "\n").toByteArray(Charsets.UTF_8))
                o.flush()
            }
        } catch (e: Exception) {
            synchronized(lock) { out = null }  // host went away; wait for reconnect
        }
    }
}
