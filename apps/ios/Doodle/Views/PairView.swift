import SwiftUI

struct PairView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showEnterCode = false
    @State private var enteredCode = ""

    private var shareMessage: String {
        let code = appState.inviteCode ?? ""
        return "Let's share doodles on our Home Screens: \(DoodleAPI.inviteLink(code: code).absoluteString)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer()
                Button("Sign out") { appState.signOut() }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text("Pair up")
                .font(.largeTitle.bold())
                .padding(.top, 4)
            Text("Doodle is for two. Share your code with your person, or enter the one they sent you.")
                .font(.body)
                .foregroundStyle(.secondary)
                .padding(.top, 8)

            VStack(spacing: 10) {
                Text("YOUR INVITE CODE")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.6)
                Group {
                    if let code = appState.inviteCode {
                        Text(code)
                            .font(.system(size: 40, weight: .semibold, design: .rounded))
                            .tracking(8)
                    } else {
                        ProgressView().frame(height: 48)
                    }
                }
                Text("Expires in 7 days. This screen continues by itself once they join.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22)
            .padding(.horizontal, 16)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .padding(.top, 36)

            Spacer()

            VStack(spacing: 10) {
                ShareLink(item: shareMessage) {
                    Label("Share invite", systemImage: "square.and.arrow.up")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .foregroundStyle(.white)
                        .background(DoodleTheme.pink, in: Capsule())
                        .opacity(appState.inviteCode == nil ? 0.4 : 1)
                }
                .disabled(appState.inviteCode == nil)

                Button {
                    showEnterCode = true
                } label: {
                    Label("I have a code", systemImage: "number")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .foregroundStyle(DoodleTheme.pink)
                        .background(DoodleTheme.pink.opacity(0.14), in: Capsule())
                }
            }
            .padding(.bottom, 24)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .background(Color(.systemGroupedBackground))
        .task {
            await appState.refreshInvite()
            await appState.watchForPartner()
        }
        .alert(
            "\(appState.pendingInvite?.inviter.name ?? "Someone") invited you",
            isPresented: Binding(
                get: { appState.pendingInvite != nil },
                set: { if !$0 { appState.declineInvite() } }
            )
        ) {
            Button("Accept") {
                // Capture now: dismissing the alert clears `pendingInvite` right after this closure.
                if let invite = appState.pendingInvite { Task { await appState.accept(invite) } }
            }
            Button("Not now", role: .cancel) { appState.declineInvite() }
        } message: {
            Text("Pair up to share doodles on each other's Home Screen.")
        }
        .alert("Enter invite code", isPresented: $showEnterCode) {
            TextField("Code", text: $enteredCode)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
            Button("Join") {
                let code = enteredCode
                enteredCode = ""
                Task { await appState.join(code: code) }
            }
            Button("Cancel", role: .cancel) { enteredCode = "" }
        } message: {
            Text("Ask your person for the 6-character code on their Pair screen.")
        }
    }
}
