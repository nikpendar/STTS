import SwiftUI
import WidgetKit

/// The watch face complication: a microphone that opens Avak and starts recording
/// (keylesswatch://record, handled in KeylessWatchApp).
@main
struct KeylessComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "KeylessMic", provider: MicProvider()) { _ in
            MicView()
                .widgetURL(URL(string: "keylesswatch://record"))
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("آواک")
        .description("ضبط صدا و تبدیل به متن فارسی با آیفون")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryRectangular, .accessoryInline])
    }
}

struct MicEntry: TimelineEntry {
    let date: Date
}

/// The complication never changes: one entry, no refreshes.
struct MicProvider: TimelineProvider {
    func placeholder(in context: Context) -> MicEntry { MicEntry(date: .now) }

    func getSnapshot(in context: Context, completion: @escaping (MicEntry) -> Void) {
        completion(MicEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MicEntry>) -> Void) {
        completion(Timeline(entries: [MicEntry(date: .now)], policy: .never))
    }
}

struct MicView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryRectangular:
            HStack {
                Image(systemName: "mic.fill")
                    .font(.title2)
                VStack(alignment: .leading) {
                    Text("آواک").font(.headline)
                    Text("گفتار به متن").font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .accessoryInline:
            Label("آواک", systemImage: "mic.fill")
        case .accessoryCorner:
            Image(systemName: "mic.fill")
                .font(.title2)
                .widgetLabel("آواک")
        default:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "mic.fill")
                    .font(.title2)
            }
        }
    }
}
