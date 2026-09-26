import Foundation
import Synchronization

extension OnlineClient {
    /// Streams `url` into a new file `file` (an existing one is refused, never replaced), reporting bytes received and
    /// the expected total; cancelling the task stops it. A partial file is removed.
    public func download(_ url: URL, to file: URL, progress: @escaping @Sendable (_ received: Int64, _ expected: Int64?) -> Void) async throws {
        try Task.checkCancellation()
        let descriptor = open(file.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard descriptor >= 0 else { throw OnlineError.file(String(cString: strerror(errno))) }
        let loader = DownloadLoader(FileHandle(fileDescriptor: descriptor, closeOnDealloc: true), progress: progress)
        let session = URLSession(configuration: self.session.configuration, delegate: loader, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.setValue(Self.browserAgent, forHTTPHeaderField: "User-Agent")
        // Received bytes are checked against the length.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let task = session.dataTask(with: request)
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    // Already cancelled, the task may have completed before it was ever resumed.
                    if loader.wait(continuation) { task.resume() }
                }
            } onCancel: {
                task.cancel()
            }
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw Task.isCancelled ? CancellationError() : error
        }
    }
}

/// Runs on the session's serial delegate queue.
private final class DownloadLoader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let handle: FileHandle
    private let progress: @Sendable (Int64, Int64?) -> Void
    private var received: Int64 = 0
    private var expected: Int64?
    private var failure: Error?
    /// Whichever comes first, the waiter or the outcome, is kept for the other.
    private let rendezvous = Mutex<(waiter: CheckedContinuation<Void, Error>?, outcome: Result<Void, Error>?)>((nil, nil))

    init(_ handle: FileHandle, progress: @escaping @Sendable (Int64, Int64?) -> Void) {
        (self.handle, self.progress) = (handle, progress)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            failure = OnlineError.http(status)
            return completionHandler(.cancel)
        }
        expected = response.expectedContentLength > 0 ? response.expectedContentLength : nil
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle.write(contentsOf: data)
        } catch {
            failure = error
            return dataTask.cancel()
        }
        received += Int64(data.count)
        progress(received, expected)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        var failure = failure ?? error
        if failure == nil, let expected, received != expected { failure = OnlineError.file("下载不完整") }
        if failure == nil {
            do { try handle.synchronize() } catch { failure = error }
        }
        try? handle.close()
        let outcome: Result<Void, Error> = failure.map { .failure($0) } ?? .success(())
        let waiter = rendezvous.withLock { state in
            if state.waiter == nil { state.outcome = outcome }
            return state.waiter.take()
        }
        waiter?.resume(with: outcome)
    }

    /// Keeps the waiter until the download completes; false (resumed already) if it has.
    func wait(_ continuation: CheckedContinuation<Void, Error>) -> Bool {
        let outcome = rendezvous.withLock { state in
            if state.outcome == nil { state.waiter = continuation }
            return state.outcome
        }
        guard let outcome else { return true }
        continuation.resume(with: outcome)
        return false
    }
}
