import Foundation
import os

private let log = Logger(subsystem: "ir.nikpendar.PersianSTT", category: "model")

/// The speech model is not inside the app, which made every build 400 MB, but imported once
/// from Files into the app's Documents folder. Installing a new build over the app keeps it.
/// The folder also shows in the Files app (On My iPhone) and in the Mac's Finder, so the model
/// can be copied there directly too.
@MainActor
final class ModelImporter: ObservableObject {
    static let shared = ModelImporter()

    /// 0...1 while a model is being copied.
    @Published private(set) var progress: Double?
    @Published private(set) var message = ""

    enum ImportError: LocalizedError {
        case notModel

        var errorDescription: String? {
            "این فایل مدل whisper نیست. فایل ggml با پسوند bin را انتخاب کنید (اگر zip است، اول در Files بازش کنید)."
        }
    }

    nonisolated static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// The imported model: a ggml file in Documents.
    nonisolated static var installedModel: URL? {
        let files = (try? FileManager.default.contentsOfDirectory(at: documents, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension.lowercased() == "bin" && isModel($0) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .first
    }

    /// ggml model files start with the magic number 0x67676d6c, stored little-endian.
    nonisolated static func isModel(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4) else { return false }
        return head.elementsEqual([0x6c, 0x6d, 0x67, 0x67])
    }

    /// Copies the picked file into Documents (replacing the model there) and loads it.
    func importModel(from source: URL) {
        guard progress == nil else { return }
        progress = 0
        message = ""
        Task {
            do {
                let destination = try await Task.detached(priority: .userInitiated) {
                    try Self.copy(source) { value in
                        Task { @MainActor in ModelImporter.shared.progress = value }
                    }
                }.value
                Self.removeModels(except: destination)
                log.info("imported \(destination.lastPathComponent, privacy: .public)")
                message = "مدل وارد شد."
                Transcriber.shared.reloadModel()
            } catch {
                log.error("import failed: \(error.localizedDescription, privacy: .public)")
                message = error.localizedDescription
            }
            progress = nil
        }
    }

    nonisolated private static func copy(_ source: URL, progress: @escaping @Sendable (Double) -> Void) throws -> URL {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        guard isModel(source) else { throw ImportError.notModel }
        var name = source.lastPathComponent
        if !name.lowercased().hasSuffix(".bin") { name += ".bin" }
        let destination = documents.appendingPathComponent(name)
        // Picked from the app's own folder (copied there with Finder): nothing to copy.
        if source.resolvingSymlinksInPath().standardizedFileURL == destination.resolvingSymlinksInPath().standardizedFileURL {
            return destination
        }
        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let partial = documents.appendingPathComponent(name + ".part")
        try? FileManager.default.removeItem(at: partial)
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: partial)
        var copied = 0
        do {
            while let chunk = try input.read(upToCount: 8 << 20), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
                copied += chunk.count
                if size > 0 { progress(Double(copied) / Double(size)) }
            }
            try output.close()
        } catch {
            try? output.close()
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partial, to: destination)
        // 400 MB that can be imported again does not belong in the iCloud backup.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var excluded = destination
        try? excluded.setResourceValues(values)
        return destination
    }

    /// One model at a time: a second one would only take space.
    private static func removeModels(except keep: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(at: documents, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension.lowercased() == "bin" && file.lastPathComponent != keep.lastPathComponent
            && isModel(file) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
