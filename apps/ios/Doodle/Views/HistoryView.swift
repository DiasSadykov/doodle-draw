import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var appState: AppState

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Button {
                        appState.route = .canvas
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.body.weight(.semibold))
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .foregroundStyle(.primary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Text("History")
                    .font(.largeTitle.bold())
                    .padding(.horizontal, 20)
                    .padding(.top, 8)

                if appState.history.isEmpty {
                    Spacer()
                    Text("No doodles yet. Send the first one.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                    Spacer()
                }

                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(appState.history) { doodle in
                            VStack(alignment: .leading, spacing: 6) {
                                Group {
                                    if let image = doodle.previewImage {
                                        Image(uiImage: image)
                                            .resizable()
                                            .scaledToFill()
                                    } else {
                                        DoodleTheme.paper
                                    }
                                }
                                .aspectRatio(1, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

                                Text(attribution(for: doodle))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 4)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 40)
                }
            }
        }
    }

    private func attribution(for doodle: DoodleDrawing) -> AttributedString {
        var who = AttributedString(doodle.from == .you ? "You" : appState.partnerName)
        who.foregroundColor = .primary
        who.font = .caption.weight(.semibold)
        var rest = AttributedString(" · \(doodle.relativeLabel)")
        rest.foregroundColor = .secondary
        rest.font = .caption
        return who + rest
    }
}
