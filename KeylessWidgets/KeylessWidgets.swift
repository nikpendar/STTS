import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// The iPhone widgets: the home screen orb, the Live Activity of a dictation and (iOS 18) the
/// Control Center and lock screen buttons. The dictation itself runs in the app
/// (`BackgroundDictation`); the intents (Shared/DictationActivity.swift) wake it there.
@main
struct KeylessWidgets: WidgetBundle {
    var body: some Widget {
        OrbWidget()
        DictationLiveActivity()
        if #available(iOS 18.0, *) {
            DictationControl()
            DictateAndCopyControl()
        }
    }
}

// MARK: - Colours

private enum Palette {
    static let orb = LinearGradient(colors: [Color(red: 1, green: 0.55, blue: 0.2), Color(red: 0.93, green: 0.25, blue: 0.35)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing)
    static let accent = Color(red: 1, green: 0.45, blue: 0.25)
}

/// The keyboard's orb: a glowing circle with the microphone.
private struct Orb: View {
    var size: CGFloat
    var paused = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Palette.orb)
                .opacity(paused ? 0.45 : 1)
                .shadow(color: Palette.accent.opacity(0.55), radius: size * 0.18)
            Circle()
                .strokeBorder(.white.opacity(0.35), lineWidth: max(1, size * 0.04))
                .padding(size * 0.08)
            Image(systemName: paused ? "pause.fill" : "mic.fill")
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Home screen orb

private struct OrbEntry: TimelineEntry {
    let date: Date
}

private struct OrbProvider: TimelineProvider {
    func placeholder(in context: Context) -> OrbEntry { OrbEntry(date: Date()) }
    func getSnapshot(in context: Context, completion: @escaping (OrbEntry) -> Void) { completion(OrbEntry(date: Date())) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<OrbEntry>) -> Void) {
        completion(Timeline(entries: [OrbEntry(date: Date())], policy: .never))
    }
}

/// A small home screen widget: one tap on the orb starts a dictation in the background (iOS 18;
/// on iOS 17 it opens the app's dictation, which copies the text).
struct OrbWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "KeylessOrb", provider: OrbProvider()) { _ in
            OrbWidgetView()
                .containerBackground(for: .widget) {
                    LinearGradient(colors: [Color(white: 0.13), Color(white: 0.06)], startPoint: .top, endPoint: .bottom)
                }
        }
        .configurationDisplayName("دیکته با کیلس")
        .description("با یک لمس، بدون باز کردن برنامه دیکته کنید.")
        .supportedFamilies([.systemSmall])
    }
}

private struct OrbWidgetView: View {
    var body: some View {
        VStack(spacing: 10) {
            if #available(iOS 18.0, *) {
                Button(intent: KeylessDictationIntent()) { Orb(size: 82) }
                    .buttonStyle(.plain)
            } else {
                // iOS 17 cannot record from the background: the app's dictation, which copies.
                Link(destination: URL(string: "persianstt://dictate")!) { Orb(size: 82) }
            }
            Text("دیکته")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
        }
        .environment(\.layoutDirection, .rightToLeft)
    }
}

// MARK: - Control Center and lock screen

@available(iOS 18.0, *)
struct DictationControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "ir.nikpendar.PersianSTT.dictation") {
            ControlWidgetButton(action: KeylessDictationIntent()) {
                Label("دیکته با کیلس", systemImage: "waveform.badge.mic")
            }
        }
        .displayName("دیکته با کیلس")
        .description("ضبط در پس‌زمینه، حتی با گوشی قفل؛ متن در برنامه ذخیره می‌شود.")
    }
}

@available(iOS 18.0, *)
struct DictateAndCopyControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "ir.nikpendar.PersianSTT.dictateCopy") {
            ControlWidgetButton(action: DictateIntent()) {
                Label("دیکته و کپی", systemImage: "doc.on.clipboard")
            }
        }
        .displayName("دیکته و کپی")
        .description("برنامه را باز می‌کند و متن را در کلیپ‌بورد کپی می‌کند.")
    }
}

// MARK: - Live Activity

struct DictationLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DictationActivityAttributes.self) { context in
            LockScreenDictation(state: context.state)
                .activityBackgroundTint(Color(white: 0.08).opacity(0.85))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Orb(size: 40, paused: context.state.phase == .paused)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ElapsedTime(state: context.state)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .trailing, spacing: 6) {
                        DictationText(state: context.state, lines: 2)
                        ActivityButtons(state: context.state)
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.phase == .paused ? "pause.fill" : "mic.fill")
                    .foregroundStyle(Palette.accent)
            } compactTrailing: {
                VoiceBars(levels: context.state.levels, count: 5, height: 14)
            } minimal: {
                Image(systemName: "mic.fill")
                    .foregroundStyle(Palette.accent)
            }
        }
    }
}

private struct LockScreenDictation: View {
    let state: DictationActivityAttributes.ContentState

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Orb(size: 46, paused: state.phase == .paused)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                    Spacer()
                    ElapsedTime(state: state)
                }
                DictationText(state: state, lines: 3)
                if state.phase == .listening || state.phase == .paused {
                    HStack {
                        VoiceBars(levels: state.levels, count: 16, height: 22)
                        Spacer()
                        ActivityButtons(state: state)
                    }
                } else if !state.note.isEmpty {
                    Text(state.note)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.accent)
                }
            }
        }
        .padding(14)
        .environment(\.layoutDirection, .rightToLeft)
    }

    private var title: String {
        switch state.phase {
        case .listening: "کیلس در حال شنیدن"
        case .paused: "مکث"
        case .transcribing: "در حال نوشتن…"
        case .done: "دیکته تمام شد"
        case .failed: "دیکته"
        }
    }
}

/// The end of the text, which is what was just said.
private struct DictationText: View {
    let state: DictationActivityAttributes.ContentState
    let lines: Int

    var body: some View {
        Text(shown)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(.white)
            .lineLimit(lines)
            .truncationMode(.head)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var shown: String {
        if !state.text.isEmpty { return state.text }
        return state.phase == .listening ? "بگویید…" : ""
    }
}

private struct ElapsedTime: View {
    let state: DictationActivityAttributes.ContentState

    var body: some View {
        if state.phase == .listening {
            Text(timerInterval: state.started...Date.distantFuture, countsDown: false)
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.7))
                .frame(maxWidth: 52)
        } else {
            EmptyView()
        }
    }
}

private struct VoiceBars: View {
    let levels: [Double]
    let count: Int
    let height: CGFloat

    var body: some View {
        let recent = Array(levels.suffix(count))
        let padded = Array(repeating: 0.0, count: max(0, count - recent.count)) + recent
        HStack(alignment: .center, spacing: 2) {
            ForEach(padded.indices, id: \.self) { index in
                Capsule()
                    .fill(Palette.orb)
                    .frame(width: 3, height: max(3, height * padded[index]))
            }
        }
        .frame(height: height)
    }
}

private struct ActivityButtons: View {
    let state: DictationActivityAttributes.ContentState

    var body: some View {
        if state.phase == .listening || state.phase == .paused {
            HStack(spacing: 10) {
                Button(intent: PauseDictationIntent()) {
                    Image(systemName: state.phase == .paused ? "play.fill" : "pause.fill")
                        .frame(width: 36, height: 30)
                }
                .tint(.white.opacity(0.25))
                Button(intent: EndDictationIntent()) {
                    Image(systemName: "stop.fill")
                        .frame(width: 36, height: 30)
                }
                .tint(Palette.accent)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .foregroundStyle(.white)
        }
    }
}
