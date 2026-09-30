import SwiftUI
import UIKit
import WidgetKit

struct DoodleEntry: TimelineEntry {
    let date: Date
    let senderName: String
    let relativeTime: String
    let timeLabel: String
    let hasPhoto: Bool
    let image: UIImage?

    static var empty: DoodleEntry {
        DoodleEntry(date: .now, senderName: "", relativeTime: "", timeLabel: "", hasPhoto: false, image: nil)
    }

    static var placeholder: DoodleEntry {
        DoodleEntry(date: .now, senderName: "Aruzhan", relativeTime: "12m", timeLabel: "12m ago", hasPhoto: false, image: nil)
    }
}

struct DoodleProvider: TimelineProvider {
    /// Below device scale (3x) so the image stays well under WidgetKit's archive size limit.
    private let pixelsPerPoint: CGFloat = 2

    func placeholder(in context: Context) -> DoodleEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (DoodleEntry) -> Void) {
        completion(makeEntry(displaySize: context.displaySize) ?? .placeholder)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<DoodleEntry>) -> Void) {
        let size = context.displaySize
        Task {
            // Ask the server for a newer doodle from the partner before drawing.
            await DoodleSync.refreshWidgetStore(reloadTimelines: false)
            let entry = makeEntry(displaySize: size) ?? .empty
            completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(15 * 60))))
        }
    }

    private func makeEntry(displaySize size: CGSize) -> DoodleEntry? {
        guard let meta = DoodleSharedStore.loadMeta() else { return nil }
        let image = DoodleSharedStore.loadImage(maxPixelSize: max(size.width, size.height) * pixelsPerPoint)
        return DoodleEntry(
            date: meta.createdAt,
            senderName: meta.senderName,
            relativeTime: meta.relativeTime,
            timeLabel: meta.timeLabel,
            hasPhoto: meta.hasPhoto,
            image: image
        )
    }
}

struct DoodleHomeWidget: Widget {
    let kind = DoodleAppGroup.widgetKind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: DoodleProvider()) { entry in
            DoodleWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    Color(red: 1, green: 0.988, blue: 0.961)
                }
        }
        .configurationDisplayName("Doodle")
        .description("Little drawings from your person, on your Home Screen.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
        .contentMarginsDisabled()
    }
}

struct DoodleWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: DoodleEntry

    private let pink = Color(red: 1, green: 0.176, blue: 0.333)
    private let paper = Color(red: 1, green: 0.988, blue: 0.961)
    private let ink = Color(red: 0.11, green: 0.11, blue: 0.118)
    private let secondaryInk = Color(red: 0.235, green: 0.235, blue: 0.263).opacity(0.6)

    var body: some View {
        switch family {
        case .systemMedium:
            mediumBody
        case .accessoryRectangular:
            lockBody
        default:
            smallBody
        }
    }

    private var smallBody: some View {
        ZStack(alignment: .bottomLeading) {
            if let image = entry.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()

                Text("\(entry.senderName) · \(entry.relativeTime)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.35), in: Capsule())
                    .padding(10)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var mediumBody: some View {
        HStack(spacing: 0) {
            ZStack {
                paper
                if let image = entry.image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                } else {
                    Image(systemName: "pencil")
                        .font(.largeTitle)
                        .foregroundStyle(pink)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            VStack(alignment: .leading, spacing: 4) {
                if entry.image != nil {
                    Text(entry.senderName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(ink)
                    Text(entry.timeLabel)
                        .font(.caption)
                        .foregroundStyle(secondaryInk)
                } else {
                    Text("No doodles yet")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(ink)
                    Text("Open Doodle to draw")
                        .font(.caption)
                        .foregroundStyle(secondaryInk)
                }
                Spacer(minLength: 0)
                Label("Draw back", systemImage: "pencil")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(pink)
            }
            .padding(.trailing, 16)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(paper)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var lockBody: some View {
        HStack(spacing: 10) {
            ZStack {
                paper
                if let image = entry.image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "pencil")
                        .foregroundStyle(pink)
                }
            }
            .frame(width: 44, height: 44)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.image == nil ? "Doodle" : entry.senderName)
                    .font(.subheadline.weight(.semibold))
                Text(entry.image == nil ? "No doodles yet" : entry.timeLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "pencil")
                .font(.title2.weight(.semibold))
                .foregroundStyle(pink)
            Spacer(minLength: 0)
            Text("No doodles yet")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(ink)
            Text("Open the app and send one")
                .font(.caption)
                .foregroundStyle(secondaryInk)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}
