// Watch-face complication: the Codex Micro RGB status lighting, on your wrist (US4).
// Families: accessoryCircular, accessoryCorner, accessoryRectangular, accessoryInline.
import WidgetKit
import SwiftUI

struct StatusEntry: TimelineEntry {
    let date: Date
    let overall: String
    let stale: Bool
    let project: String

    var status: SessionStatus { SessionStatus(rawValue: overall) ?? .idle }
    var color: Color { stale ? .gray : status.color }
    var symbol: String {
        if stale { return "wifi.slash" }
        switch status {
        case .needsInput: return "hand.raised.fill"
        case .thinking, .working: return "brain"
        case .complete: return "checkmark"
        case .error: return "exclamationmark.triangle.fill"
        default: return "moon.zzz"
        }
    }
}

struct StatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> StatusEntry {
        StatusEntry(date: .now, overall: "idle", stale: false, project: "claude")
    }
    func getSnapshot(in context: Context, completion: @escaping (StatusEntry) -> Void) {
        completion(current())
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<StatusEntry>) -> Void) {
        // Reloaded on demand by the watch app on every state change (WidgetCenter.reloadAllTimelines);
        // fallback refresh keeps the "stale" honesty guarantee (Constitution VI).
        completion(Timeline(entries: [current()], policy: .after(.now.addingTimeInterval(15 * 60))))
    }
    private func current() -> StatusEntry {
        let s = ComplicationState.read()
        return StatusEntry(date: .now, overall: s.overall, stale: s.stale, project: s.project)
    }
}

struct StatusComplicationView: View {
    @Environment(\.widgetFamily) var family
    let entry: StatusEntry

    var body: some View {
        switch family {
        case .accessoryRectangular:
            HStack {
                Circle().fill(entry.color).frame(width: 10, height: 10)
                VStack(alignment: .leading) {
                    Text("Claude").font(.headline)
                    Text(entry.stale ? "stale" : entry.status.label).font(.caption2)
                    if !entry.project.isEmpty { Text(entry.project).font(.caption2).foregroundStyle(.secondary) }
                }
            }
            .containerBackground(for: .widget) { Color.clear }
        case .accessoryInline:
            Label(entry.stale ? "Claude: stale" : "Claude: \(entry.status.label)", systemImage: entry.symbol)
                .containerBackground(for: .widget) { Color.clear }
        default: // circular & corner
            ZStack {
                Circle().stroke(entry.color, lineWidth: 3)
                Image(systemName: entry.symbol).font(.system(size: 16, weight: .bold)).foregroundStyle(entry.color)
            }
            .widgetLabel { Text(entry.stale ? "stale" : entry.status.label) }
            .containerBackground(for: .widget) { Color.clear }
        }
    }
}

@main
struct StatusComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ClaudeMicroStatus", provider: StatusProvider()) { entry in
            StatusComplicationView(entry: entry)
        }
        .configurationDisplayName("Claude Status")
        .description("Agent status at a glance — the RGB lighting analog.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryInline, .accessoryRectangular])
    }
}
