import Foundation

/// Performs the proxy's outbound request via URLSession. Redirects are NOT
/// followed (the client re-requests through the proxy, so we capture each hop),
/// and per-task metrics give us time-to-first-byte.
///
/// **Nothing here may outlive the capture session that built it.** A session-wide
/// `URLSession(configuration:delegate:…)` retains its delegate until it is invalidated, so an
/// `UpstreamClient` used as its own delegate could never deallocate: every tab start/stop, and
/// every `restartForInterceptChange()`, stranded a session, its delegate operation queue and its
/// connection pool for the life of the process. The metrics were keyed by task identifier in a
/// dictionary only the completion handler pruned, so any task that completed without one (an
/// early failure, a cancel) left an entry behind — unbounded growth on the per-request path.
/// Both go away by keeping the session delegate-less and giving each request its own delegate.
final class UpstreamClient: @unchecked Sendable {
    struct Response: Sendable {
        var statusCode: Int
        var headers: [(String, String)]
        var body: Data
        var responseStart: Date?
        var responseEnd: Date?
        var error: String?
    }

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.httpShouldUsePipelining = false
        config.connectionProxyDictionary = [:]   // go direct; never recurse through a system proxy
        config.timeoutIntervalForRequest = 60
        session = URLSession(configuration: config)
    }

    /// Lets the connection pool and its threads go once the capture session that owns this client
    /// does. Reachable now only because the session has no delegate to retain us.
    deinit { session.finishTasksAndInvalidate() }

    func send(_ request: URLRequest) async -> Response {
        // Per task, so its lifetime is the request's — there is no dictionary to prune and no
        // entry that can be orphaned by a task that fails before metrics are collected.
        let observer = TaskObserver()
        do {
            let (data, response) = try await session.data(for: request, delegate: observer)
            let http = response as? HTTPURLResponse
            let headers: [(String, String)] = (http?.allHeaderFields ?? [:]).compactMap { key, value in
                guard let k = key as? String else { return nil }
                return (k, "\(value)")
            }
            let metric = observer.lastTransactionMetric()
            return Response(
                statusCode: http?.statusCode ?? 0,
                headers: headers,
                body: data,
                responseStart: metric?.responseStartDate,
                responseEnd: metric?.responseEndDate ?? Date(),
                error: nil
            )
        } catch {
            let metric = observer.lastTransactionMetric()
            return Response(
                statusCode: 0, headers: [], body: Data(),
                responseStart: metric?.responseStartDate,
                responseEnd: metric?.responseEndDate ?? Date(),
                error: error.localizedDescription
            )
        }
    }
}

/// One request's delegate: refuses redirects and keeps that request's metrics.
private final class TaskObserver: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var metrics: URLSessionTaskMetrics?

    func lastTransactionMetric() -> URLSessionTaskTransactionMetrics? {
        lock.lock(); defer { lock.unlock() }
        return metrics?.transactionMetrics.last
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)  // capture the 3xx; let the client re-request through us
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didFinishCollecting metrics: URLSessionTaskMetrics) {
        lock.lock(); self.metrics = metrics; lock.unlock()
    }
}
