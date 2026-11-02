import Foundation
import CryptoKit

/// EmbeddingGemma 300M (8-bit GGUF): turns a notification into a vector so it can be compared with the
/// ones the user reacted to. Multilingual in one space, so a Korean reaction also covers English messages.
/// Downloaded once on first run; the file is checked against a pinned SHA-256.
enum EmbeddingModel {
    static let url = URL(string: "https://huggingface.co/ggml-org/embeddinggemma-300M-GGUF/resolve/main/embeddinggemma-300M-Q8_0.gguf")!
    static let sha256 = "b5ce9d77a3fc4b3b39ccb5643c36777911cc4eb46a66962eadfa3f5f60490d63"
    static let size: Int64 = 333_590_944

    static var fileURL: URL {
        ConfigStore.directory.appendingPathComponent("models/embeddinggemma-300M-Q8_0.gguf")
    }

    static var isDownloaded: Bool {
        (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) == size
    }

    /// SHA-256 of a file, read in chunks so a few hundred MB never sit in memory.
    static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Downloads the model in the background and reports progress to the setup window.
final class ModelDownloader: NSObject, ObservableObject, URLSessionDownloadDelegate {
    /// 0...1 while downloading, nil otherwise.
    @Published private(set) var progress: Double?
    @Published private(set) var error: String?
    @Published private(set) var isReady = EmbeddingModel.isDownloaded
    var onReady: (() -> Void)?

    func start() {
        guard !isReady, progress == nil else { return }
        error = nil
        progress = 0
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        session.downloadTask(with: EmbeddingModel.url).resume()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : EmbeddingModel.size
        let p = Double(totalBytesWritten) / Double(total)
        DispatchQueue.main.async { self.progress = p }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file is gone once this returns, so check and move it here.
        let dest = EmbeddingModel.fileURL
        var failure: String?
        if EmbeddingModel.sha256(of: location) != EmbeddingModel.sha256 {
            failure = "The download didn't match the expected file. Try again."
        } else {
            try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: dest)
            do { try FileManager.default.moveItem(at: location, to: dest) } catch { failure = "Couldn't save the model: \(error.localizedDescription)" }
        }
        DispatchQueue.main.async {
            self.progress = nil
            self.error = failure
            self.isReady = failure == nil && EmbeddingModel.isDownloaded
            if self.isReady { self.onReady?() }
        }
        session.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        DispatchQueue.main.async {
            self.progress = nil
            self.error = "Download failed: \(error.localizedDescription)"
        }
        session.finishTasksAndInvalidate()
    }
}

/// Runs llama.cpp's `llama-server` (bundled in the app) with the embedding model on 127.0.0.1, only while
/// it's needed: it starts on the first request (about a second) and stops after 10 idle minutes, since
/// it holds roughly 450 MB.
/// `@unchecked Sendable`: its state (process, port, idle timer) is only touched on `queue`.
final class EmbeddingService: @unchecked Sendable {
    private let queue = DispatchQueue(label: "focusdock.embedding")
    private var process: Process?
    private var port = 0
    private var idleStop: DispatchWorkItem?
    private let idleSeconds: TimeInterval = 600

    /// The bundled server, or Homebrew's while developing with `swift run`.
    static var serverURL: URL? {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("llama/llama-server")
        return [bundled, URL(fileURLWithPath: "/opt/homebrew/bin/llama-server")]
            .compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    var isAvailable: Bool { Self.serverURL != nil && EmbeddingModel.isDownloaded }

    /// A zip downloaded with a browser marks every file in it as quarantined, and macOS refuses to run a
    /// quarantined helper ("FocusDock Not Opened") even after the person allowed the app. They did allow
    /// it, so its bundled server is cleared too. Fails quietly where the app can't write (run from Downloads).
    static func clearQuarantine(in dir: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for file in files { removexattr(file.path, "com.apple.quarantine", 0) }
    }

    /// A unit vector for `text`, or nil if the model or server isn't available.
    func embed(_ text: String) async -> [Float]? {
        guard isAvailable else { return nil }
        let port: Int? = queue.sync { ensureRunning() ? self.port : nil }
        guard let port, let url = URL(string: "http://127.0.0.1:\(port)/embedding") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["content": Self.prompt(text)])
        defer { queue.async { self.scheduleIdleStop() } }
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
        return Self.parseEmbedding(data)
    }

    func stop() {
        queue.sync {
            idleStop?.cancel()
            process?.terminate()
            process = nil
            try? FileManager.default.removeItem(at: Self.pidFile)
        }
    }

    /// EmbeddingGemma expects a task prefix; symmetric similarity is what nearest-reaction matching needs.
    static func prompt(_ text: String) -> String { "task: sentence similarity | query: " + text }

    /// `/embedding` answers `[{"index": 0, "embedding": [[…]]}]` or `{"embedding": […]}`; returns it normalized.
    static func parseEmbedding(_ data: Data) -> [Float]? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let entry = (obj as? [[String: Any]])?.first ?? (obj as? [String: Any])
        var raw = entry?["embedding"] as? [Any]
        if let nested = raw?.first as? [Any] { raw = nested }
        guard let values = raw?.compactMap({ ($0 as? NSNumber)?.floatValue }), !values.isEmpty else { return nil }
        let norm = sqrt(values.reduce(0) { $0 + $1 * $1 })
        return norm > 0 ? values.map { $0 / norm } : nil
    }

    // MARK: Server lifecycle (on `queue`)

    private static var pidFile: URL { ConfigStore.directory.appendingPathComponent("llama-server.pid") }

    private func ensureRunning() -> Bool {
        if let p = process, p.isRunning { return true }
        Self.killLeftover()
        for _ in 0..<2 {   // a second try if the random port was taken
            if start() { return true }
        }
        return false
    }

    private func start() -> Bool {
        guard let server = Self.serverURL else { return false }
        if server.path.hasPrefix(Bundle.main.bundlePath + "/") {
            Self.clearQuarantine(in: server.deletingLastPathComponent())
        }
        let port = Int.random(in: 49_152...64_000)
        let p = Process()
        p.executableURL = server
        p.arguments = ["-m", EmbeddingModel.fileURL.path, "--embedding", "--host", "127.0.0.1",
                       "--port", "\(port)", "-ngl", "99"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        try? "\(p.processIdentifier)".write(to: Self.pidFile, atomically: true, encoding: .utf8)
        // Ready when /health says so; give up after 20 s (first load from disk is the slow part).
        let health = URL(string: "http://127.0.0.1:\(port)/health")!
        for _ in 0..<80 {
            guard p.isRunning else { return false }
            if let data = try? Data(contentsOf: health), String(decoding: data, as: UTF8.self).contains("ok") {
                process = p
                self.port = port
                return true
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        p.terminate()
        return false
    }

    private func scheduleIdleStop() {
        idleStop?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.process?.terminate()
            self?.process = nil
        }
        idleStop = work
        queue.asyncAfter(deadline: .now() + idleSeconds, execute: work)
    }

    /// Stops a server a previous FocusDock left running (crash or force quit). Call at launch.
    static func cleanUpLeftover() { killLeftover() }

    /// A server left behind by a FocusDock that crashed or was killed.
    private static func killLeftover() {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8), let pid = Int32(text) else { return }
        // Only if that pid is still a llama-server (pids get reused).
        let ps = Process(), out = Pipe()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-p", "\(pid)", "-o", "comm="]
        ps.standardOutput = out
        guard (try? ps.run()) != nil else { return }
        ps.waitUntilExit()
        let name = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        if name.contains("llama-server") { kill(pid, SIGTERM) }
        try? FileManager.default.removeItem(at: pidFile)
    }
}
