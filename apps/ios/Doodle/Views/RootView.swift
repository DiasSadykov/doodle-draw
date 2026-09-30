import SwiftUI

struct RootView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch appState.route {
            case .launching:
                LaunchView()
            case .signIn:
                SignInView()
            case .pair:
                PairView()
            case .canvas:
                CanvasScreen()
            case .latest:
                LatestView()
            case .history:
                HistoryView()
            }
        }
        .animation(.easeInOut(duration: 0.25), value: appState.route)
        .task { await appState.bootstrap() }
        .onOpenURL { url in Task { await appState.handle(url: url) } }
        // Fresh doodles whenever we land on a screen that shows them, and when returning to the app.
        .task(id: appState.route) { await appState.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await appState.refresh() } }
        }
        .alert(
            "Doodle",
            isPresented: Binding(
                get: { appState.alertMessage != nil },
                set: { if !$0 { appState.alertMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(appState.alertMessage ?? "")
        }
    }
}

private struct LaunchView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 16) {
            AppIconView(size: 88)
            if let error = appState.launchError {
                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Button("Try again") { Task { await appState.bootstrap() } }
                    .buttonStyle(.borderedProminent)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}
