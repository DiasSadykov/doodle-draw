import SwiftUI

struct LatestView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()

            VStack(spacing: 0) {
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
                    Text("From \(appState.partnerName)")
                        .font(.headline)
                    Spacer()
                    Color.clear.frame(width: 44, height: 44)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                if let latest = appState.latestFromPartner {
                    Group {
                        if let image = latest.previewImage {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                        } else {
                            DoodleTheme.paper
                        }
                    }
                    .frame(width: 361, height: 361)
                    .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
                    .padding(.top, 28)

                    Text("\(appState.partnerName) · \(latest.relativeLabel) ago")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.top, 16)
                } else {
                    Spacer()
                    Text("Nothing from \(appState.partnerName) yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    appState.route = .canvas
                } label: {
                    Label("Draw Back", systemImage: "pencil")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .foregroundStyle(.white)
                        .background(DoodleTheme.pink, in: Capsule())
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
        }
    }
}
