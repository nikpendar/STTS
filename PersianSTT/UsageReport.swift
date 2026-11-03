import SwiftUI
import UIKit

/// The app's own dictations (Siri, the widget, the Control Center button), counted in the
/// same report as the keyboard's.
enum AppUsage {
    private static let appKey = "appUsageStats"
    private static let baselineKey = "usageBaseline"
    private static let keyboardKey = "usageLastKeyboard"
    private static let sinceKey = "usageSince"

    static func recordDictation(words: Int, seconds: Double) {
        var stats = load(appKey) ?? .zero
        stats.voiceWords += words
        stats.voiceSeconds += seconds
        stats.dictations += 1
        save(stats, appKey)
    }

    /// Everything since the last reset: the keyboard's totals less those at the reset, plus the app's.
    static func report() -> UsageStats {
        var keyboard = load(keyboardKey) ?? .zero
        if let latest = UsageStats.fromKeyboard() {
            keyboard = latest
            save(latest, keyboardKey)
        }
        var baseline = load(baselineKey) ?? .zero
        if keyboard.isBelow(baseline) {
            baseline = .zero
            save(baseline, baselineKey)
        }
        return (keyboard - baseline) + (load(appKey) ?? .zero)
    }

    static var since: Date? {
        UserDefaults.standard.object(forKey: sinceKey) as? Date
    }

    static func reset() {
        let keyboard = UsageStats.fromKeyboard() ?? load(keyboardKey) ?? .zero
        save(keyboard, baselineKey)
        save(.zero, appKey)
        UserDefaults.standard.set(Date(), forKey: sinceKey)
    }

    /// The report as a JSON file to send: counts only, no text.
    static func exportFile() -> URL? {
        let stats = report()
        var info: [String: Any] = [
            "app": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            "ios": UIDevice.current.systemVersion,
            "device": deviceModel,
            "date": ISO8601DateFormatter().string(from: Date()),
            "secondsSaved": Int(stats.secondsSaved),
            "glideMeters": (stats.glideMeters * 10).rounded() / 10,
        ]
        if let since { info["since"] = ISO8601DateFormatter().string(from: since) }
        if let data = try? JSONEncoder().encode(stats),
           let counts = try? JSONSerialization.jsonObject(with: data) {
            info["counts"] = counts
        }
        guard let json = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("keyless-usage.json")
        try? json.write(to: url)
        return url
    }

    private static var deviceModel: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: info.machine) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
    }

    private static func load(_ key: String) -> UsageStats? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(UsageStats.self, from: $0) }
    }

    private static func save(_ stats: UsageStats, _ key: String) {
        if let data = try? JSONEncoder().encode(stats) { UserDefaults.standard.set(data, forKey: key) }
    }
}

/// The report page: time saved, words by voice, glide lines, corrections and predictions,
/// with sending and resetting.
struct UsageReportPage: View {
    @State private var stats = AppUsage.report()
    @State private var confirmingReset = false
    @State private var exportURL: URL?

    var body: some View {
        Section {
            row("زمان صرفه‌جویی‌شده", duration(stats.secondsSaved), symbol: "clock.fill", color: .green)
        } footer: {
            Text("در مقایسه با تایپ روی گوشی (حدود ۳۰ کلمه در دقیقه): زمان تایپ کلمه‌های دیکته‌شده منهای زمان گفتنشان، به‌علاوه‌ی حرف‌هایی که پیشنهادها لازم نکردند.")
        }
        Section {
            row("کلمه‌های نوشته‌شده با صدا", number(stats.voiceWords), symbol: "waveform", color: .red)
            row("تعداد دیکته‌ها", number(stats.dictations), symbol: "mic.fill", color: .orange)
            row("مدت صحبت", duration(stats.voiceSeconds), symbol: "timer", color: .orange)
            row("دیکته‌هایی که خودتان اصلاح کردید", number(stats.voiceFixes), symbol: "pencil", color: .pink)
            row("کلمه‌های اصلاح‌شده در دیکته‌ها", number(stats.voiceWordsFixed), symbol: "text.badge.xmark", color: .pink)
        } header: {
            Text("صدا")
        }
        Section {
            row("کلمه‌های نوشته‌شده با کشیدن", number(stats.glideWords), symbol: "scribble", color: .blue)
            row("طول خط‌های کشیده‌شده", meters(stats.glideMeters), symbol: "ruler.fill", color: .blue)
            row("غلط‌هایی که خودکار اصلاح شد", number(stats.autoCorrections), symbol: "checkmark.circle.fill", color: .teal)
            row("اصلاح‌هایی که برگرداندید", number(stats.autoCorrectionsUndone), symbol: "arrow.uturn.backward.circle.fill", color: .gray)
            row("کلمه‌های انتخاب‌شده از پیشنهادها", number(stats.predictionsPicked), symbol: "text.word.spacing", color: .purple)
            row("حرف‌هایی که لازم نشد تایپ کنید", number(stats.lettersSaved), symbol: "character.cursor.ibeam", color: .purple)
        } header: {
            Text("تایپ")
        } footer: {
            if let since = AppUsage.since {
                Text("از \(since.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(Locale(identifier: "fa_IR")))). آمار کیبورد هر بار که کیبورد بسته می‌شود به‌روز می‌شود.")
            } else {
                Text("آمار کیبورد هر بار که کیبورد بسته می‌شود به‌روز می‌شود.")
            }
        }
        Section {
            if let exportURL {
                ShareLink(item: exportURL) {
                    Label("فرستادن آمار برای ما", systemImage: "paperplane.fill")
                }
            }
            Button(role: .destructive) {
                confirmingReset = true
            } label: {
                Label("ریست کامل آمار", systemImage: "arrow.counterclockwise")
            }
        } footer: {
            Text("فقط عددها فرستاده می‌شود، نه متنی که نوشته‌اید.")
        }
        .confirmationDialog("همه‌ی آمار صفر شود؟", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("ریست", role: .destructive) {
                AppUsage.reset()
                refresh()
            }
        }
        .onAppear(perform: refresh)
    }

    private func refresh() {
        stats = AppUsage.report()
        exportURL = AppUsage.exportFile()
    }

    private func row(_ title: String, _ value: String, symbol: String, color: Color) -> some View {
        LabeledContent {
            Text(value).monospacedDigit()
        } label: {
            Label {
                Text(title)
            } icon: {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 27, height: 27)
                    .background(RoundedRectangle(cornerRadius: 7).fill(color))
            }
        }
    }

    private static let persian = Locale(identifier: "fa_IR")

    private func number(_ value: Int) -> String {
        value.formatted(.number.locale(Self.persian))
    }

    private func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let rest = total % 60
        if hours > 0 { return "\(number(hours)) ساعت و \(number(minutes)) دقیقه" }
        if minutes > 0 { return "\(number(minutes)) دقیقه و \(number(rest)) ثانیه" }
        return "\(number(rest)) ثانیه"
    }

    private func meters(_ value: Double) -> String {
        value >= 1000
            ? "\((value / 1000).formatted(.number.precision(.fractionLength(2)).locale(Self.persian))) کیلومتر"
            : "\(value.formatted(.number.precision(.fractionLength(1)).locale(Self.persian))) متر"
    }
}

/// The dictations started without the app on screen, newest first; a tap copies one.
struct DictationHistoryPage: View {
    @State private var entries = DictationHistory.all()
    @State private var copiedID: UUID?

    var body: some View {
        Section {
            if entries.isEmpty {
                Text("هنوز دیکته‌ای با سیری، ویجت یا دکمه‌ی مرکز کنترل انجام نشده.")
                    .foregroundStyle(.secondary)
            }
            ForEach(entries) { entry in
                Button {
                    UIPasteboard.general.string = entry.text
                    copiedID = entry.id
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Locale(identifier: "fa_IR")))
                             + (copiedID == entry.id ? " · کپی شد" : ""))
                            .font(.app(.subheadline))
                            .foregroundStyle(.secondary)
                        Text(entry.text)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                    }
                }
            }
        } footer: {
            Text("سیری: «Hey Siri, Keyless dictation» (با گوشی قفل هم). برای کپی، روی هر متن بزنید.")
        }
        if !entries.isEmpty {
            Section {
                Button("پاک کردن همه", role: .destructive) {
                    DictationHistory.removeAll()
                    entries = []
                }
            }
        }
    }
}
