import CoreML
import Foundation
import os

private let log = Logger(subsystem: "ir.nikpendar.PersianSTT", category: "model")

/// The speech model (Shenava Koochik, a 212 MB Core ML .mlmodel file) is not inside the app,
/// so each build stays a few MB, but imported once from Files and compiled on the phone into
/// Application Support. Installing a new build over the app keeps it. A .mlmodel copied with
/// Finder into the app's Documents folder (On My iPhone › کیلس) is imported at the next launch.
@MainActor
final class ModelImporter: ObservableObject {
    static let shared = ModelImporter()

    /// Set while a model is being imported (no fraction: Core ML's compiler reports none).
    @Published private(set) var progress: Double?
    @Published private(set) var message = ""

    enum ImportError: LocalizedError {
        case notModel

        var errorDescription: String? {
            "این فایل مدل گفتار نیست. فایل Koochik.mlmodel را انتخاب کنید (اگر zip است، اول در Files بازش کنید)."
        }
    }

    nonisolated static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    nonisolated static var modelsDir: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Models", isDirectory: true)
    }

    /// The imported model, compiled.
    nonisolated static var installedModel: URL? {
        let url = modelsDir.appendingPathComponent("Koochik.mlmodelc", isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// A .mlmodel put into Documents with Finder, not imported yet.
    nonisolated static var waitingModel: URL? {
        let files = (try? FileManager.default.contentsOfDirectory(at: documents, includingPropertiesForKeys: nil)) ?? []
        return files.first { $0.pathExtension.lowercased() == "mlmodel" }
    }

    /// Compiles the picked .mlmodel into Application Support (replacing the model there) and loads it.
    func importModel(from source: URL) {
        guard progress == nil else { return }
        progress = 0
        message = "در حال آماده کردن مدل… ممکن است یک دقیقه طول بکشد."
        Task {
            do {
                try await Self.install(source)
                log.info("imported \(source.lastPathComponent, privacy: .public)")
                message = "مدل وارد شد."
                Transcriber.shared.reloadModel()
            } catch {
                log.error("import failed: \(error.localizedDescription, privacy: .public)")
                message = error is ImportError ? error.localizedDescription
                    : "فایل مدل باز نشد؛ ممکن است ناقص کپی شده باشد. " + error.localizedDescription
            }
            progress = nil
        }
    }

    /// Imports a model copied into Documents with Finder.
    func importWaitingModel() {
        guard progress == nil, let waiting = Self.waitingModel else { return }
        importModel(from: waiting)
    }

    nonisolated private static func install(_ source: URL) async throws {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        guard source.pathExtension.lowercased() == "mlmodel" else { throw ImportError.notModel }
        let compiled = try await MLModel.compileModel(at: source)
        defer { try? FileManager.default.removeItem(at: compiled) }
        let fm = FileManager.default
        try fm.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        let target = modelsDir.appendingPathComponent("Koochik.mlmodelc", isDirectory: true)
        let staging = modelsDir.appendingPathComponent("Koochik.mlmodelc.new", isDirectory: true)
        try? fm.removeItem(at: staging)
        try fm.copyItem(at: compiled, to: staging)
        try? fm.removeItem(at: target)
        try fm.moveItem(at: staging, to: target)
        // 200 MB that can be imported again does not belong in the iCloud backup.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var excluded = target
        try? excluded.setResourceValues(values)
        // The .mlmodel itself, if it was in the app's folder, and the Whisper model of earlier
        // versions (ggml-*.bin, 444 MB) are no longer needed.
        let documentsFiles = (try? fm.contentsOfDirectory(at: documents, includingPropertiesForKeys: nil)) ?? []
        for file in documentsFiles where ["bin", "part"].contains(file.pathExtension.lowercased())
            || file.standardizedFileURL == source.standardizedFileURL {
            try? fm.removeItem(at: file)
        }
    }
}
