import SwiftUI

struct SignInView: View {
    @EnvironmentObject private var appState: AppState
    // Test sign-in only. Remembered on this device so you type them once.
    @AppStorage("devName") private var name = ""
    @AppStorage("devKey") private var devKey = ""

    private var canContinue: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !appState.isBusy
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            AppIconView(size: 112)
            Text("Doodle")
                .font(.largeTitle.bold())
                .padding(.top, 24)
            Text("Little drawings for your person,\nright on their Home Screen.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
            Spacer()

            VStack(spacing: 10) {
                field { TextField("Your name", text: $name).textContentType(.givenName) }
                field { SecureField("Test key", text: $devKey) }
            }
            .padding(.horizontal, 28)

            Button {
                Task { await appState.signIn(name: name, devKey: devKey) }
            } label: {
                Group {
                    if appState.isBusy {
                        ProgressView().tint(.white)
                    } else {
                        Text("Continue").font(.headline)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .foregroundStyle(.white)
                .background(DoodleTheme.pink, in: Capsule())
                .opacity(canContinue ? 1 : 0.4)
            }
            .disabled(!canContinue)
            .padding(.horizontal, 28)
            .padding(.top, 14)

            Text("Test sign-in. Google sign-in comes later.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 14)
                .padding(.bottom, 32)
        }
        .background(Color(.systemBackground))
    }

    private func field<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .padding(.horizontal, 16)
            .frame(height: 50)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
