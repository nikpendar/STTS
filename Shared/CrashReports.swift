import Foundation
import MetricKit
import UIKit

/// Crash, hang and abnormal-exit reports that iOS collects for the app and the keyboard
/// (MetricKit), with no outside service. iOS hands each process its own reports, at the latest a
/// day later: the app keeps its reports in Application Support/CrashReports; the keyboard, which
/// shares no folder with the app (no App Group), puts its reports on a named pasteboard, and the
/// app files them when it opens. The app's «گزارش خرابی‌ها» page lists and shares them.
final class CrashReports: NSObject, MXMetricManagerSubscriber {
    static let shared = CrashReports()

    /// One stored report: a payload as MetricKit writes it (JSON).
    struct Report: Identifiable, Equatable {
        let url: URL
        let date: Date
        /// «برنامه» or «کیبورد».
        let source: String
        /// What happened, in Persian: the kinds of diagnostics and the first crash's exception.
        let summary: String
        var id: URL { url }
    }

    private static let pasteboardName = UIPasteboard.Name("ir.nikpendar.PersianSTT.crashReports")
    private static let pasteboardType = "public.json"
    /// The newest reports kept.
    private static let kept = 30
    private static var isKeyboard: Bool { Bundle.main.bundleURL.pathExtension == "appex" }

    private var started = false

    /// Starts receiving this process's reports (once per process).
    func start() {
        guard !started else { return }
        started = true
        MXMetricManager.shared.add(self)
        if !Self.isKeyboard { collectFromKeyboard() }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads { store(payload.jsonRepresentation()) }
    }

    /// Daily metrics matter only when the process was killed: out of memory, a watchdog, a crash.
    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads where Self.abnormalExits(payload) > 0 { store(payload.jsonRepresentation()) }
    }

    private static func abnormalExits(_ payload: MXMetricPayload) -> Int {
        guard let exits = payload.applicationExitMetrics else { return 0 }
        let fg = exits.foregroundExitData, bg = exits.backgroundExitData
        return fg.cumulativeMemoryResourceLimitExitCount + fg.cumulativeAbnormalExitCount
            + fg.cumulativeAppWatchdogExitCount + fg.cumulativeBadAccessExitCount
            + fg.cumulativeIllegalInstructionExitCount
            + bg.cumulativeMemoryResourceLimitExitCount
            + bg.cumulativeAbnormalExitCount + bg.cumulativeAppWatchdogExitCount
            + bg.cumulativeBadAccessExitCount + bg.cumulativeIllegalInstructionExitCount
            + bg.cumulativeCPUResourceLimitExitCount
    }

    private func store(_ json: Data) {
        if Self.isKeyboard {
            UIPasteboard(name: Self.pasteboardName, create: true)?.addItems([[Self.pasteboardType: json]])
        } else {
            Self.write(json, source: "app")
        }
    }

    /// App side: files the reports the keyboard left on the pasteboard.
    func collectFromKeyboard() {
        guard let board = UIPasteboard(name: Self.pasteboardName, create: false), board.numberOfItems > 0 else { return }
        for item in board.items {
            if let json = item[Self.pasteboardType] as? Data { Self.write(json, source: "keyboard") }
        }
        board.items = []
    }

    // MARK: - Stored reports (app)

    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("CrashReports", isDirectory: true)
    }

    private static func write(_ json: Data, source: String) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = folder.appendingPathComponent("\(source)-\(stamp)-\(UUID().uuidString.prefix(4)).json")
        try? json.write(to: url)
        for old in all().dropFirst(kept) { try? FileManager.default.removeItem(at: old.url) }
    }

    /// The stored reports, newest first.
    static func all() -> [Report] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        return urls.filter { $0.pathExtension == "json" }.map { url in
            let date = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let source = url.lastPathComponent.hasPrefix("keyboard") ? "کیبورد" : "برنامه"
            return Report(url: url, date: date, source: source, summary: summary(of: url))
        }.sorted { $0.date > $1.date }
    }

    static func removeAll() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// The kinds of diagnostics in a payload, with the first crash's exception and signal.
    private static func summary(of url: URL) -> String {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "نامعلوم" }
        let kinds: [(key: String, name: String)] = [
            ("crashDiagnostics", "خرابی"), ("hangDiagnostics", "گیرکردن"),
            ("cpuExceptionDiagnostics", "مصرف زیاد پردازنده"), ("diskWriteExceptionDiagnostics", "نوشتن زیاد روی حافظه"),
            ("appLaunchDiagnostics", "باز شدن کند"),
        ]
        var parts = kinds.compactMap { kind -> String? in
            guard let list = json[kind.key] as? [Any], !list.isEmpty else { return nil }
            return list.count > 1 ? "\(kind.name) ×\(list.count)" : kind.name
        }
        if json["applicationExitMetrics"] != nil { parts.append("بسته شدن ناگهانی (گزارش روزانه)") }
        if let crash = (json["crashDiagnostics"] as? [[String: Any]])?.first,
           let meta = crash["diagnosticMetaData"] as? [String: Any] {
            let detail = [meta["exceptionType"], meta["signal"], meta["terminationReason"]]
                .compactMap { $0.map { "\($0)" } }.joined(separator: ", ")
            if !detail.isEmpty { parts.append(detail) }
        }
        return parts.isEmpty ? "گزارش بدون مورد" : parts.joined(separator: " · ")
    }
}
