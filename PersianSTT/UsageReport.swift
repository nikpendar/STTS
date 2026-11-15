import SwiftUI
import UIKit

/// The report's totals: the keyboard's, less those it had at the last reset, plus the
/// dictations of the Apple Watch app, which the app writes itself (`WatchLink`).
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
            "accuracy": stats.accuracy.map { ($0 * 1000).rounded() / 1000 } ?? NSNull(),
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
    /// The personal dictionary, for adding a frequent mistake in one tap.
    @Binding var dictionary: PersonalDictionary
    @State private var stats = AppUsage.report()
    @State private var mistakes: [DictionarySuggestions.Suggestion] = []
    @State private var confirmingReset = false
    @State private var exportURL: URL?

    var body: some View {
        Section {
            row(L("زمان صرفه‌جویی‌شده", "Time Saved"), duration(stats.secondsSaved), symbol: "clock.fill", color: .green)
        } footer: {
            Text(L("در مقایسه با تایپ روی گوشی (حدود ۳۰ کلمه در دقیقه): زمان تایپ کلمه‌های دیکته‌شده منهای زمان گفتنشان، به‌علاوه‌ی حرف‌هایی که پیشنهادها لازم نکردند.", "Compared with typing on the phone (about 30 words a minute): the time to type the dictated words less the time spent saying them, plus the letters the suggestions spared."))
        }
        accuracySection
        if !mistakes.isEmpty {
            Section {
                ForEach(mistakes.prefix(5)) { mistake in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(mistake.heard) ← \(mistake.written)")
                            Text(L("\(number(mistake.count)) بار", "\(number(mistake.count)) times"))
                                .font(.app(.caption))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            dictionary.entries.append(PersonalDictionary.Entry(heard: mistake.heard, written: mistake.written))
                            refresh()
                        } label: {
                            Label(L("افزودن به واژه‌نامه", "Add to Dictionary"), systemImage: "plus.circle.fill")
                                .labelStyle(.iconOnly)
                                .font(.title3)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            } header: {
                Text(L("غلط‌های پرتکرار دیکته", "Frequent Dictation Mistakes"))
            } footer: {
                Text(L("با + به واژه‌نامه‌ی شخصی اضافه می‌شود و از آن به بعد خودکار درست نوشته می‌شود.", "+ adds it to the personal dictionary, and from then on it is written correctly."))
            }
        }
        Section {
            row(L("کلمه‌های نوشته‌شده با صدا", "Words Written by Voice"), number(stats.voiceWords), symbol: "waveform", color: .red)
            row(L("تعداد دیکته‌ها", "Dictations"), number(stats.dictations), symbol: "mic.fill", color: .orange)
            row(L("مدت صحبت", "Speaking Time"), duration(stats.voiceSeconds), symbol: "timer", color: .orange)
            row(L("دیکته‌هایی که خودتان اصلاح کردید", "Dictations You Corrected"), number(stats.voiceFixes), symbol: "pencil", color: .pink)
            row(L("کلمه‌های اصلاح‌شده در دیکته‌ها", "Words Corrected in Dictations"), number(stats.voiceWordsFixed), symbol: "text.badge.xmark", color: .pink)
        } header: {
            Text(L("صدا", "Voice"))
        }
        Section {
            row(L("کلمه‌های نوشته‌شده با کشیدن", "Words Written by Gliding"), number(stats.glideWords), symbol: "scribble", color: .blue)
            row(L("طول خط‌های کشیده‌شده", "Length of Glide Lines"), meters(stats.glideMeters), symbol: "ruler.fill", color: .blue)
            row(L("غلط‌هایی که خودکار اصلاح شد", "Typos Corrected Automatically"), number(stats.autoCorrections), symbol: "checkmark.circle.fill", color: .teal)
            row(L("اصلاح‌هایی که برگرداندید", "Corrections You Undid"), number(stats.autoCorrectionsUndone), symbol: "arrow.uturn.backward.circle.fill", color: .gray)
            row(L("کلمه‌های انتخاب‌شده از پیشنهادها", "Words Picked from Suggestions"), number(stats.predictionsPicked), symbol: "text.word.spacing", color: .purple)
            row(L("حرف‌هایی که لازم نشد تایپ کنید", "Letters You Did Not Have to Type"), number(stats.lettersSaved), symbol: "character.cursor.ibeam", color: .purple)
        } header: {
            Text(L("تایپ", "Typing"))
        } footer: {
            if let since = AppUsage.since {
                Text(L("از ", "Since ") + since.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(AppLanguage.locale)) + L(". آمار کیبورد هر بار که کیبورد بسته می‌شود به‌روز می‌شود.", ". The keyboard's counts update while it is open and each time it closes."))
            } else {
                Text(L("آمار کیبورد هر بار که کیبورد بسته می‌شود به‌روز می‌شود.", "The keyboard's counts update while it is open and each time it closes."))
            }
        }
        Section {
            if let exportURL {
                ShareLink(item: exportURL) {
                    Label(L("فرستادن آمار برای ما", "Send Us the Counts"), systemImage: "paperplane.fill")
                }
            }
            Button(role: .destructive) {
                confirmingReset = true
            } label: {
                Label(L("ریست کامل آمار", "Reset All Counts"), systemImage: "arrow.counterclockwise")
            }
        } footer: {
            Text(L("فقط عددها فرستاده می‌شود، نه متنی که نوشته‌اید.", "Only the numbers are sent, not the text you wrote."))
        }
        .confirmationDialog(L("همه‌ی آمار صفر شود؟", "Reset all counts to zero?"), isPresented: $confirmingReset, titleVisibility: .visible) {
            Button(L("ریست", "Reset"), role: .destructive) {
                AppUsage.reset()
                refresh()
            }
        }
        .onAppear(perform: refresh)
    }

    private func refresh() {
        stats = AppUsage.report()
        mistakes = DictionarySuggestions.list(excluding: dictionary)
        exportURL = AppUsage.exportFile()
    }

    /// The user's own word error rate from their edits of dictated text, overall and per week,
    /// with the weeks a new personal model came.
    @ViewBuilder private var accuracySection: some View {
        let weeks = stats.weeks.filter { $0.value.count == 2 && $0.value[0] >= 20 }
            .sorted { $0.key > $1.key }
            .prefix(8)
        let updates = Set((UserDefaults.standard.array(forKey: PersonalModel.updatesKey) as? [Date] ?? []).map { UsageStats.week(of: $0) })
        Section {
            row(L("دقت دیکته", "Dictation Accuracy"), stats.accuracy.map(percent) ?? L("هنوز کافی نیست", "Not enough yet"), symbol: "target", color: .mint)
            row(L("کلمه‌های سنجیده‌شده", "Words Checked"), number(max(0, stats.checkedWords)), symbol: "text.magnifyingglass", color: .mint)
            ForEach(Array(weeks), id: \.key) { week in
                LabeledContent {
                    Text(percent(max(0, 1 - Double(week.value[1]) / Double(week.value[0])))).monospacedDigit()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(weekTitle(week.key))
                        Text(L("\(number(week.value[0])) کلمه", "\(number(week.value[0])) words") + (updates.contains(week.key) ? L(" · مدل شخصی تازه", " · new personal model") : ""))
                            .font(.app(.caption))
                            .foregroundStyle(updates.contains(week.key) ? Color.green : Color.secondary)
                    }
                }
            }
        } header: {
            Text(L("دقت روی صدای شما", "Accuracy on Your Voice"))
        } footer: {
            Text(L("از اصلاح‌هایی که روی متن دیکته‌شده انجام می‌دهید: کلمه‌های عوض‌شده، حذف‌شده یا اضافه‌شده تقسیم بر کلمه‌های دیکته. دیکته‌ی اصلاح‌نشده درست حساب می‌شود و بازنویسی‌های بزرگ (بیش از نیمی از کلمه‌ها) شمرده نمی‌شوند.", "From your edits of dictated text: words changed, deleted or added, divided by the dictated words. An uncorrected dictation counts as right, and large rewrites (more than half the words) are not counted."))
        }
    }

    private func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0)).locale(Self.persian))
    }

    /// "این هفته", "هفته‌ی پیش" or the week's first day.
    private func weekTitle(_ key: String) -> String {
        if key == UsageStats.week() { return L("این هفته", "This week") }
        if key == UsageStats.week(of: Date().addingTimeInterval(-7 * 86_400)) { return L("هفته‌ی پیش", "Last week") }
        let parts = key.split(separator: "-").compactMap { Int($0) }
        var components = DateComponents()
        components.yearForWeekOfYear = parts.first
        components.weekOfYear = parts.last
        components.weekday = 2
        guard parts.count == 2, let date = Calendar(identifier: .iso8601).date(from: components) else { return key }
        return L("هفته‌ی ", "Week of ") + date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(Self.persian))
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

    private static var persian: Locale { AppLanguage.locale }

    private func number(_ value: Int) -> String {
        value.formatted(.number.locale(Self.persian))
    }

    private func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let rest = total % 60
        if hours > 0 { return L("\(number(hours)) ساعت و \(number(minutes)) دقیقه", "\(number(hours)) h \(number(minutes)) min") }
        if minutes > 0 { return L("\(number(minutes)) دقیقه و \(number(rest)) ثانیه", "\(number(minutes)) min \(number(rest)) s") }
        return L("\(number(rest)) ثانیه", "\(number(rest)) s")
    }

    private func meters(_ value: Double) -> String {
        value >= 1000
            ? L("\((value / 1000).formatted(.number.precision(.fractionLength(2)).locale(Self.persian))) کیلومتر", "\((value / 1000).formatted(.number.precision(.fractionLength(2)).locale(Self.persian))) km")
            : L("\(value.formatted(.number.precision(.fractionLength(1)).locale(Self.persian))) متر", "\(value.formatted(.number.precision(.fractionLength(1)).locale(Self.persian))) m")
    }
}
