import AuthenticationServices
import SwiftUI

struct SignInView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme

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

            SignInWithAppleButton(.continue) { request in
                request.requestedScopes = [.fullName]
            } onCompletion: { result in
                handle(result)
            }
            .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
            .frame(height: 52)
            .clipShape(Capsule())
            .padding(.horizontal, 28)
            .disabled(appState.isBusy)
            .opacity(appState.isBusy ? 0.5 : 1)

            #if DEBUG
            TestSignIn()
                .padding(.horizontal, 28)
                .padding(.top, 16)
            PrototypeEntry()
                .padding(.horizontal, 28)
                .padding(.top, 8)
            #endif

            Color.clear.frame(height: 32)
        }
        .background(Color(.systemBackground))
    }

    private func handle(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard
                let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                let data = credential.identityToken,
                let token = String(data: data, encoding: .utf8)
            else {
                appState.alertMessage = "Apple didn't send back a sign-in. Please try again."
                return
            }
            let name = credential.fullName?.givenName
            Task { await appState.signInWithApple(identityToken: token, givenName: name) }
        case .failure(let error):
            if (error as? ASAuthorizationError)?.code == .canceled { return }
            appState.alertMessage = "Sign in with Apple failed. Please try again."
        }
    }
}

#if DEBUG
/// Fake-person login so one developer can try pairing with two "people". Not in release builds.
private struct TestSignIn: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage("devName") private var name = ""
    @AppStorage("devKey") private var devKey = ""
    @State private var expanded = false

    var body: some View {
        DisclosureGroup("Test sign-in", isExpanded: $expanded) {
            VStack(spacing: 10) {
                field { TextField("Name", text: $name) }
                field { SecureField("Test key", text: $devKey) }
                Button("Continue as \(name.isEmpty ? "…" : name)") {
                    Task { await appState.signInForTesting(name: name, devKey: devKey) }
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || appState.isBusy)
            }
            .padding(.top, 10)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    private func field<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .foregroundStyle(.primary)
    }
}

/// Opens the Multiple users redesign prototype, which runs on sample data. Not in release builds.
private struct PrototypeEntry: View {
    @AppStorage("prototypeMode") private var prototypeMode = false

    var body: some View {
        Button("Try the Multiple users redesign") { prototypeMode = true }
            .font(.footnote.weight(.semibold))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif
