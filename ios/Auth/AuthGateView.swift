// Sign-up / log-in screen in the Death Terminal look (black, glowing green).
// Wrap the app's root view:  AuthGate { ContentView() }

import SwiftUI

@MainActor
public struct AuthGate<Content: View>: View {
    @StateObject private var auth = DTAuth()
    @Environment(\.scenePhase) private var phase
    private let content: () -> Content

    public init(@ViewBuilder content: @escaping () -> Content) { self.content = content }

    public var body: some View {
        Group {
            if auth.isSignedIn {
                content().environmentObject(auth)
            } else {
                DTLoginView().environmentObject(auth)
            }
        }
        .task { await auth.restore() }
        .onChange(of: phase) { _, p in if p == .active { Task { await auth.restore() } } }
    }
}

@MainActor
struct DTLoginView: View {
    @EnvironmentObject private var auth: DTAuth
    enum Mode { case logIn, signUp, reset }
    @State private var mode: Mode = .logIn
    @State private var email = ""
    @State private var password = ""
    @State private var confirm = ""
    @State private var note: String?
    @State private var noteIsError = false
    @State private var busy = false

    private let green = Color(red: 0.25, green: 1.0, blue: 0.45)

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 18) {
                    // Add the glowing green skull logo (death-terminal-logo-full.png)
                    // to the asset catalog as "DTLogo".
                    Image("DTLogo").resizable().scaledToFit().frame(width: 120, height: 120)
                        .shadow(color: green.opacity(0.6), radius: 18)
                    Text("YouNeeK Death Terminal").font(.system(.title2, design: .monospaced).bold()).foregroundStyle(green)
                    Text("The terminal you'll never leave.").font(.system(.footnote, design: .monospaced)).foregroundStyle(green.opacity(0.7))

                    Picker("", selection: $mode) {
                        Text("Log in").tag(Mode.logIn)
                        Text("Create account").tag(Mode.signUp)
                        Text("Forgot").tag(Mode.reset)
                    }.pickerStyle(.segmented)

                    field("Email", text: $email).textContentType(.emailAddress).keyboardType(.emailAddress)
                    if mode != .reset {
                        secure("Password", text: $password).textContentType(mode == .signUp ? .newPassword : .password)
                    }
                    if mode == .signUp { secure("Confirm password", text: $confirm).textContentType(.newPassword) }

                    if let note {
                        Text(note).font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(noteIsError ? Color.red : green).multilineTextAlignment(.center)
                    }

                    Button(action: submit) {
                        Text(busy ? "..." : title).font(.system(.headline, design: .monospaced))
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(green).foregroundStyle(.black).clipShape(RoundedRectangle(cornerRadius: 10))
                    }.disabled(busy)
                }
                .padding(28)
            }
        }
        .preferredColorScheme(.dark)
        .tint(green)
    }

    private var title: String {
        switch mode {
        case .logIn: return "Log in"
        case .signUp: return "Create account"
        case .reset: return "Send reset link"
        }
    }

    private func field(_ label: String, text: Binding<String>) -> some View {
        TextField(label, text: text).textInputAutocapitalization(.never).autocorrectionDisabled()
            .font(.system(.body, design: .monospaced)).padding(12)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(green.opacity(0.6)))
            .foregroundStyle(green)
    }

    private func secure(_ label: String, text: Binding<String>) -> some View {
        SecureField(label, text: text).font(.system(.body, design: .monospaced)).padding(12)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(green.opacity(0.6)))
            .foregroundStyle(green)
    }

    private func submit() {
        let e = email.trimmingCharacters(in: .whitespaces)
        guard e.contains("@"), e.contains(".") else { return show("That doesn't look like an email address.", error: true) }
        if mode == .signUp {
            guard password.count >= 8 else { return show("Use a password of at least 8 characters.", error: true) }
            guard password == confirm else { return show("The passwords don't match.", error: true) }
        }
        busy = true
        Task {
            defer { busy = false }
            do {
                switch mode {
                case .logIn: try await auth.logIn(email: e, password: password)
                case .signUp: try await auth.signUp(email: e, password: password)
                case .reset:
                    try await auth.resetPassword(email: e)
                    show("If that email has an account, a reset link is on its way.", error: false)
                }
            } catch DTAuthError.confirmEmail {
                show("Almost there: we emailed a link to \(e). Tap it, then log in.", error: false)
                mode = .logIn
            } catch {
                show(error.localizedDescription, error: true)
            }
        }
    }

    private func show(_ m: String, error: Bool) { note = m; noteIsError = error }
}
