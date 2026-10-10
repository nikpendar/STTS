import CryptoKit
import Foundation
import os

private let log = Logger(subsystem: "ir.nikpendar.PersianSTT", category: "personal")

/// Learning from the user's corrections (see server/ in the repository).
///
/// When the user edits dictated text, the keyboard reports the corrected text; the recording
/// and both texts are queued on disk and uploaded to the user's own training server. The
/// server fine-tunes the model and publishes new versions, which are downloaded here and
/// replace the bundled model.
@MainActor
final class PersonalModel: ObservableObject {
    static let shared = PersonalModel()

    static let uploadKey = "trainingUpload"
    static let serverKey = "trainingServer"
    static let autoUpdateKey = "trainingAutoUpdate"
    static let versionKey = "personalModelVersion"
    static let defaultServer = "http://mac-mini.local:8765"

    /// Corrected dictations waiting for upload.
    @Published private(set) var pending = 0
    /// One line about the server and the last upload or check.
    @Published private(set) var serverStatus = ""
    /// A newer model on the server than the one in use.
    @Published private(set) var available: Release?
    /// 0...1 while a model downloads.
    @Published private(set) var downloadProgress: Double?
    @Published private(set) var version = UserDefaults.standard.integer(forKey: PersonalModel.versionKey)

    struct Release: Decodable, Equatable {
        let version: Int
        let size: Int
        let sha256: String
        let werBefore: Double?
        let werAfter: Double?
        let samples: Int?

        enum CodingKeys: String, CodingKey {
            case version, size, sha256, samples
            case werBefore = "wer_before"
            case werAfter = "wer_after"
        }
    }

    private struct UploadReply: Decodable {
        let samples: Int
    }

    private struct ServerStatus: Decodable {
        let samples: Int
        let training: Bool
    }

    private let queueDir: URL
    let modelsDir: URL
    private var uploading = false
    private var progressObservation: NSKeyValueObservation?
    private static let lastCheckKey = "personalModelLastCheck"

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        queueDir = support.appendingPathComponent("TrainingQueue", isDirectory: true)
        modelsDir = support.appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: queueDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        pending = queuedFiles().count
    }

    private var server: URL? {
        let text = UserDefaults.standard.string(forKey: Self.serverKey) ?? Self.defaultServer
        return URL(string: text.trimmingCharacters(in: .whitespaces))
    }

    private var uploadEnabled: Bool { UserDefaults.standard.bool(forKey: Self.uploadKey) }

    // MARK: - Corrections

    private struct QueuedSample: Codable {
        let id: String
        let original: String
        let corrected: String
        let audio: String
    }

    /// Queues a corrected dictation and tries to upload it. Whisper hears 30 s at a time, so
    /// longer recordings cannot be matched to their text and are not used.
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
            .filter { $0.pathExtension == "json" } ?? []
    }

    /// Uploads the queue in order; stops at the first failure and keeps the rest for later.
    func upload() async {
        guard uploadEnabled, !uploading, let server else { return }
        uploading = true
        defer { uploading = false }
        for file in queuedFiles() {
            guard let body = try? Data(contentsOf: file) else { continue }
            var request = URLRequest(url: server.appendingPathComponent("samples"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 30
            do {
                let (data, response) = try await URLSession.shared.upload(for: request, from: body)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    serverStatus = "سرور نمونه را نپذیرفت: \(String(decoding: data, as: UTF8.self))"
                    break
                }
                try? FileManager.default.removeItem(at: file)
                if let reply = try? JSONDecoder().decode(UploadReply.self, from: data) {
                    serverStatus = "\(reply.samples) نمونه روی سرور"
                }
            } catch {
                serverStatus = "سرور در دسترس نیست: \(error.localizedDescription)"
                break
            }
        }
        pending = queuedFiles().count
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

    // MARK: - Server

    /// Asks the server for its sample count and newest model; downloads it when automatic
    /// updates are on.
    func check(automatic: Bool = false) async {
        guard let server else { return }
        if automatic {
            let last = UserDefaults.standard.double(forKey: Self.lastCheckKey)
            guard Date().timeIntervalSince1970 - last > 6 * 3600 else { return }
        }
        do {
            let (statusData, _) = try await URLSession.shared.data(from: server.appendingPathComponent("status"))
            if let status = try? JSONDecoder().decode(ServerStatus.self, from: statusData) {
                serverStatus = "\(status.samples) نمونه روی سرور" + (status.training ? "، در حال آموزش" : "")
            }
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
            let (data, response) = try await URLSession.shared.data(from: server.appendingPathComponent("model/latest"))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                available = nil
                return
            }
            let release = try JSONDecoder().decode(Release.self, from: data)
            available = release.version > version ? release : nil
            log.info("server has model v\(release.version), using v\(self.version)")
            if available != nil, UserDefaults.standard.bool(forKey: Self.autoUpdateKey) {
                download()
            }
        } catch {
            serverStatus = "سرور در دسترس نیست: \(error.localizedDescription)"
        }
    }

    /// Asks the server to train now on everything it has.
    func train() async {
        guard let server else { return }
        var request = URLRequest(url: server.appendingPathComponent("train"))
        request.httpMethod = "POST"
        if (try? await URLSession.shared.data(for: request)) != nil {
            serverStatus = "آموزش روی سرور شروع شد"
        } else {
            serverStatus = "سرور در دسترس نیست"
        }
    }

    func download() {
        guard let release = available, downloadProgress == nil, let server else { return }
        downloadProgress = 0
        let task = URLSession.shared.downloadTask(with: server.appendingPathComponent("model/\(release.version)")) { url, response, error in
            // The temporary file is deleted when this handler returns, so it is moved first.
            var moved: URL?
            if let url, (response as? HTTPURLResponse)?.statusCode == 200 {
                let target = FileManager.default.temporaryDirectory.appendingPathComponent("personal-\(release.version).bin")
                try? FileManager.default.removeItem(at: target)
                if (try? FileManager.default.moveItem(at: url, to: target)) != nil { moved = target }
            }
            let message = error?.localizedDescription
            Task { @MainActor in self.finishDownload(release, file: moved, error: message) }
        }
        progressObservation = task.progress.observe(\.fractionCompleted) { progress, _ in
            let fraction = progress.fractionCompleted
            Task { @MainActor in if self.downloadProgress != nil { self.downloadProgress = fraction } }
        }
        task.resume()
    }

    private func finishDownload(_ release: Release, file: URL?, error: String?) {
        progressObservation = nil
        downloadProgress = nil
        guard let file else {
            serverStatus = "دانلود ناموفق بود" + (error.map { ": \($0)" } ?? "")
            return
        }
        Task {
            let valid = await Task.detached { Self.sha256(of: file) == release.sha256 }.value
            guard valid else {
                try? FileManager.default.removeItem(at: file)
                serverStatus = "فایل دانلودشده سالم نبود"
                log.error("downloaded model v\(release.version) failed the checksum")
                return
            }
            let target = modelsDir.appendingPathComponent("ggml-personal-v\(release.version).bin")
            try? FileManager.default.removeItem(at: target)
            do {
                try FileManager.default.moveItem(at: file, to: target)
            } catch {
                serverStatus = "ذخیره‌ی مدل ناموفق بود"
                return
            }
            removeModels(except: target)
            setVersion(release.version)
            available = nil
            serverStatus = "نسخه‌ی \(release.version) نصب شد"
            log.info("installed personal model v\(release.version)")
            Transcriber.shared.reloadModel()
        }
    }

    /// Goes back to the model inside the app.
    func useBundledModel() {
        removeModels(except: nil)
        setVersion(0)
        Transcriber.shared.reloadModel()
    }

    /// The downloaded model in use, if any.
    var modelFile: URL? {
        guard version > 0 else { return nil }
        let file = modelsDir.appendingPathComponent("ggml-personal-v\(version).bin")
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    private func setVersion(_ value: Int) {
        version = value
        UserDefaults.standard.set(value, forKey: Self.versionKey)
    }

    private func removeModels(except keep: URL?) {
        for file in (try? FileManager.default.contentsOfDirectory(at: modelsDir, includingPropertiesForKeys: nil)) ?? []
        where file.lastPathComponent.hasPrefix("ggml-personal-") && file != keep {
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
