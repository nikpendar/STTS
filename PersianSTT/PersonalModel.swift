import CoreML
import CryptoKit
import Foundation
import Security
import os

private let log = Logger(subsystem: "ir.nikpendar.PersianSTT", category: "personal")

/// Learning from the user's corrections, with GitHub as the free server (see training/ in the
/// repository).
///
/// When the user edits dictated text, the keyboard reports the corrected text; the recording
/// and both texts are queued on disk and uploaded to the user's private GitHub repository
/// (samples/<id>.wav and .json) with their own access token. A scheduled workflow of this
/// project fine-tunes the model on them and, when the new model transcribes held-out samples
/// better, publishes it as a release of that repository; it is downloaded and compiled here and
/// replaces the imported model.
@MainActor
final class PersonalModel: ObservableObject {
    static let shared = PersonalModel()

    static let uploadKey = "trainingUpload"
    static let autoUpdateKey = "trainingAutoUpdate"
    static let versionKey = "personalModelVersion"
    /// The private repository, owner/name: TRAINING_REPO in config.env, which the build puts in
    /// Info.plist (TrainingRepository); this when a build has none.
    static let defaultRepo = "nikpendar/keyless-training"

    /// Corrected dictations waiting for upload.
    @Published private(set) var pending = 0
    /// One line about the repository and the last upload or check.
    @Published private(set) var status = ""
    /// A newer model in the repository than the one in use.
    @Published private(set) var available: Release?
    /// 0...1 while a model downloads; 1 while it is compiled.
    @Published private(set) var downloadProgress: Double?
    @Published private(set) var version = UserDefaults.standard.integer(forKey: PersonalModel.versionKey)

    /// What the training workflow writes into a release's description.
    struct Release: Decodable, Equatable {
        let version: Int
        let size: Int
        let sha256: String
        let werBefore: Double?
        let werAfter: Double?
        let samples: Int?
        /// The asset's API address and its file's extension (mlmodel or aar), filled in from the release.
        var asset: URL?
        var assetKind = "mlmodel"

        enum CodingKeys: String, CodingKey {
            case version, size, sha256, samples
            case werBefore = "wer_before"
            case werAfter = "wer_after"
        }
    }

    private struct GitHubRelease: Decodable {
        let body: String?
        let assets: [Asset]

        struct Asset: Decodable {
            let name: String
            let url: URL
        }
    }

    /// status.json, written by the training workflow.
    private struct TrainingStatus: Decodable {
        let samples: Int
        let trainedOn: Int?
        let result: String?

        enum CodingKeys: String, CodingKey {
            case samples, result
            case trainedOn = "trained_on"
        }
    }

    private let queueDir: URL
    let modelsDir = ModelImporter.modelsDir
    private var uploading = false
    private var progressObservation: NSKeyValueObservation?
    private static let lastCheckKey = "personalModelLastCheck"

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        queueDir = support.appendingPathComponent("TrainingQueue", isDirectory: true)
        try? FileManager.default.createDirectory(at: queueDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        pending = queuedFiles().count
        removeModels(except: modelFile)
    }

    private var uploadEnabled: Bool { UserDefaults.standard.bool(forKey: Self.uploadKey) }

    /// owner/name of the private repository.
    private var repo: String {
        if Self.testAPI != nil, let test = UserDefaults.standard.string(forKey: "trainingRepository") { return test }
        let configured = (Bundle.main.object(forInfoDictionaryKey: "TrainingRepository") as? String)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return configured.contains("/") ? configured : Self.defaultRepo
    }

    /// The GitHub access token (fine-grained, Contents read and write on the repository only),
    /// kept in the Keychain.
    var token: String {
        get {
            if Self.testAPI != nil, let test = UserDefaults.standard.string(forKey: "trainingTestToken") { return test }
            return Keychain.read(Self.tokenAccount) ?? ""
        }
        set {
            Keychain.write(Self.tokenAccount, newValue.trimmingCharacters(in: .whitespacesAndNewlines))
            objectWillChange.send()
        }
    }
    private static let tokenAccount = "githubTrainingToken"

    /// CI only: launch arguments `-trainingAPI <url> -trainingTestToken <token>` point the app
    /// at the live test's stand-in for GitHub (Tests/github_stub.py).
    private static let testAPI = UserDefaults.standard.string(forKey: "trainingAPI")

    // MARK: - Corrections

    private struct QueuedSample: Codable {
        let id: String
        let original: String
        let corrected: String
        let audio: String
    }

    /// Queues a corrected dictation and tries to upload it. Recordings over 30 s are left out:
    /// training holds a whole recording in memory at once.
    func add(id: String, samples: [Float], original: String, corrected: String) {
        guard uploadEnabled, samples.count <= 30 * 16_000 else { return }
        let sample = QueuedSample(id: id, original: original, corrected: corrected,
                                  audio: Self.wav(samples).base64EncodedString())
        do {
            try JSONEncoder().encode(sample).write(to: queueDir.appendingPathComponent("\(id).json"))
        } catch {
            log.error("cannot queue sample: \(error.localizedDescription, privacy: .public)")
            return
        }
        log.info("queued correction \(id, privacy: .public)")
        pending = queuedFiles().count
        Task { await upload() }
    }

    private func queuedFiles() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: queueDir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
    }

    /// Uploads the queue: the recording, then its texts, which mark the sample complete. Stops
    /// at the first failure and keeps the rest for later.
    func upload() async {
        guard uploadEnabled, !uploading, !token.isEmpty else { return }
        uploading = true
        defer { uploading = false }
        var sent = 0
        for file in queuedFiles() {
            guard let data = try? Data(contentsOf: file),
                  let sample = try? JSONDecoder().decode(QueuedSample.self, from: data) else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            let meta: [String: Any] = [
                "id": sample.id, "original": sample.original, "corrected": sample.corrected,
                "date": ISO8601DateFormatter().string(from: Date()),
            ]
            guard let metaData = try? JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys]) else { continue }
            do {
                try await put("samples/\(sample.id).wav", base64: sample.audio)
                try await put("samples/\(sample.id).json", base64: metaData.base64EncodedString())
            } catch {
                status = error.localizedDescription
                break
            }
            try? FileManager.default.removeItem(at: file)
            sent += 1
        }
        pending = queuedFiles().count
        if sent > 0 { status = "\(sent) اصلاح به مخزن فرستاده شد" }
    }

    enum GitHubError: LocalizedError {
        case unauthorized, notFound, failed(Int), offline(String)

        var errorDescription: String? {
            switch self {
            case .unauthorized: return "توکن GitHub درست نیست یا منقضی شده است."
            case .notFound: return "مخزن پیدا نشد یا توکن به آن دسترسی ندارد."
            case .failed(let code): return "GitHub خطا داد (\(code))."
            case .offline(let message): return "GitHub در دسترس نیست: \(message)"
            }
        }
    }

    private func request(_ path: String, method: String = "GET") -> URLRequest {
        let url = "\(Self.testAPI ?? "https://api.github.com")/repos/\(repo)" + (path.isEmpty ? "" : "/\(path)")
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.timeoutInterval = 60
        return request
    }

    private func send(_ request: URLRequest, body: Data? = nil) async throws -> (Data, Int) {
        do {
            let data: Data
            let response: URLResponse
            if let body {
                (data, response) = try await URLSession.shared.upload(for: request, from: body)
            } else {
                (data, response) = try await URLSession.shared.data(for: request)
            }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch code {
            case 200..<300: return (data, code)
            case 401: throw GitHubError.unauthorized
            case 403, 404: throw GitHubError.notFound
            default: return (data, code)
            }
        } catch let error as GitHubError {
            throw error
        } catch {
            throw GitHubError.offline(error.localizedDescription)
        }
    }

    /// Creates a file in the repository. One that is already there (sent before the app was
    /// stopped) counts as sent.
    private func put(_ path: String, base64: String) async throws {
        var request = request("contents/\(path)", method: "PUT")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = try JSONSerialization.data(withJSONObject: ["message": "Sample \(path)", "content": base64])
        let (_, code) = try await send(request, body: body)
        guard code < 300 || code == 422 else { throw GitHubError.failed(code) }
    }

    /// 16 kHz mono 16-bit PCM WAV.
    static func wav(_ samples: [Float]) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); append(36 + bytes)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(16_000)); append(UInt32(32_000)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(bytes)
        for sample in samples {
            append(Int16(max(-1, min(1, sample)) * 32767))
        }
        return data
    }

    // MARK: - New models

    /// Reads the training status and the newest release; downloads it when automatic updates
    /// are on. Automatic checks run at most every 6 hours.
    func check(automatic: Bool = false) async {
        guard !token.isEmpty else { return }
        if automatic {
            let last = UserDefaults.standard.double(forKey: Self.lastCheckKey)
            guard Date().timeIntervalSince1970 - last > 6 * 3600 else { return }
        }
        do {
            var raw = request("contents/status.json")
            raw.setValue("application/vnd.github.raw+json", forHTTPHeaderField: "Accept")
            if let reply = try? await send(raw), reply.1 == 200,
               let training = try? JSONDecoder().decode(TrainingStatus.self, from: reply.0) {
                var line = "\(training.samples) نمونه در مخزن"
                if let trained = training.trainedOn { line += "، \(trained) در آخرین آموزش" }
                if let result = training.result, !result.isEmpty { line += "\n" + result }
                status = line
            }
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
            // Before the first training run there is no release, and GitHub answers 404 for a
            // repository it does serve: only the repository itself says whether it can be reached.
            var code = 0, data = Data()
            do {
                (data, code) = try await send(request("releases/latest"))
            } catch GitHubError.notFound {
                _ = try await send(request(""))
            }
            guard code == 200 else {
                available = nil
                if status.isEmpty { status = "هنوز مدل شخصی منتشر نشده است" }
                return
            }
            let latest = try JSONDecoder().decode(GitHubRelease.self, from: data)
            guard var release = latest.body.flatMap({ try? JSONDecoder().decode(Release.self, from: Data($0.utf8)) }),
                  let asset = latest.assets.first(where: { ModelArchive.extensions.contains(($0.name as NSString).pathExtension) }) else {
                available = nil
                return
            }
            release.asset = asset.url
            release.assetKind = (asset.name as NSString).pathExtension
            available = release.version > version ? release : nil
            log.info("repository has model v\(release.version), using v\(self.version)")
            if available != nil, UserDefaults.standard.bool(forKey: Self.autoUpdateKey) {
                download()
            }
        } catch {
            status = error.localizedDescription
        }
    }

    func download() {
        guard let release = available, let asset = release.asset, downloadProgress == nil else { return }
        downloadProgress = 0
        var request = URLRequest(url: asset)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        let task = Self.downloads.downloadTask(with: request) { url, response, error in
            // The temporary file is deleted when this handler returns, so it is moved first.
            var moved: URL?
            if let url, (response as? HTTPURLResponse)?.statusCode == 200 {
                let target = FileManager.default.temporaryDirectory.appendingPathComponent("personal-\(release.version).\(release.assetKind)")
                try? FileManager.default.removeItem(at: target)
                if (try? FileManager.default.moveItem(at: url, to: target)) != nil { moved = target }
            }
            let message = error?.localizedDescription
            Task { @MainActor in self.finishDownload(release, file: moved, error: message) }
        }
        progressObservation = task.progress.observe(\.fractionCompleted) { progress, _ in
            let fraction = progress.fractionCompleted
            Task { @MainActor in if self.downloadProgress != nil { self.downloadProgress = min(fraction, 0.99) } }
        }
        task.resume()
    }

    private static let downloads = URLSession(configuration: .default, delegate: RedirectDelegate(), delegateQueue: nil)

    private func finishDownload(_ release: Release, file: URL?, error: String?) {
        progressObservation = nil
        guard let file else {
            downloadProgress = nil
            status = "دانلود ناموفق بود" + (error.map { ": \($0)" } ?? "")
            return
        }
        downloadProgress = 1
        Task {
            defer {
                downloadProgress = nil
                try? FileManager.default.removeItem(at: file)
            }
            let valid = await Task.detached { Self.sha256(of: file) == release.sha256 }.value
            guard valid else {
                status = "فایل دانلودشده سالم نبود"
                log.error("downloaded model v\(release.version) failed the checksum")
                return
            }
            let target = modelsDir.appendingPathComponent("personal-v\(release.version).mlmodelc", isDirectory: true)
            do {
                let compiled = try await ModelArchive.compile(file)
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.copyItem(at: compiled, to: target)
                try? FileManager.default.removeItem(at: compiled)
            } catch {
                status = "آماده کردن مدل ناموفق بود: \(error.localizedDescription)"
                return
            }
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var excluded = target
            try? excluded.setResourceValues(values)
            removeModels(except: target)
            setVersion(release.version)
            available = nil
            status = "نسخه‌ی \(release.version) نصب شد"
            log.info("installed personal model v\(release.version)")
            Transcriber.shared.reloadModel()
        }
    }

    /// Goes back to the imported model.
    func useBaseModel() {
        removeModels(except: nil)
        setVersion(0)
        Transcriber.shared.reloadModel()
    }

    /// The downloaded model in use, if any.
    var modelFile: URL? {
        guard version > 0 else { return nil }
        let file = modelsDir.appendingPathComponent("personal-v\(version).mlmodelc", isDirectory: true)
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    private func setVersion(_ value: Int) {
        version = value
        UserDefaults.standard.set(value, forKey: Self.versionKey)
    }

    /// Older personal models, and the Whisper ones of earlier versions (ggml-personal-*.bin).
    private func removeModels(except keep: URL?) {
        for file in (try? FileManager.default.contentsOfDirectory(at: modelsDir, includingPropertiesForKeys: nil)) ?? []
        where (file.lastPathComponent.hasPrefix("personal-") || file.lastPathComponent.hasPrefix("ggml-"))
            && file.standardizedFileURL != keep?.standardizedFileURL {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private nonisolated static func sha256(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Release assets redirect to a storage host that rejects the GitHub token, so it is dropped
/// on the redirect.
private final class RedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        var request = request
        if request.url?.host != task.originalRequest?.url?.host {
            request.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        completionHandler(request)
    }
}

/// A string per account in the app's Keychain.
enum Keychain {
    private static let service = "ir.nikpendar.PersianSTT"

    static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ account: String, _ value: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }
}
