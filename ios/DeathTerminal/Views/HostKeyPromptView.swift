import SwiftUI

/// Sheet shown for a new or changed host key.
struct HostKeyPromptView: View {
    let challenge: HostKeyChallenge
    let answer: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(challenge.changedFrom == nil ? "New host" : "HOST KEY CHANGED",
                  systemImage: challenge.changedFrom == nil ? "questionmark.diamond" : "exclamationmark.octagon.fill")
                .font(Theme.mono(20, weight: .bold))
                .foregroundStyle(challenge.changedFrom == nil ? Theme.green : Theme.danger)
            if let old = challenge.changedFrom {
                Text("The key for \(challenge.host) is different from the one you trusted before. Someone could be intercepting this connection.")
                    .foregroundStyle(Theme.text)
                Text("Old: \(old)").font(Theme.mono(12)).foregroundStyle(.secondary).textSelection(.enabled)
            } else {
                Text("The authenticity of \(challenge.host) can't be established yet. Check the fingerprint matches the server before trusting it.")
                    .foregroundStyle(Theme.text)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(challenge.keyType).font(Theme.mono(13)).foregroundStyle(.secondary)
                Text(challenge.fingerprint).font(Theme.mono(13, weight: .semibold))
                    .foregroundStyle(Theme.green).textSelection(.enabled)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
            HStack {
                Button("Cancel", role: .cancel) { answer(false) }
                    .buttonStyle(.bordered)
                Spacer()
                Button(challenge.changedFrom == nil ? "Trust & connect" : "Replace key & connect") { answer(true) }
                    .buttonStyle(.borderedProminent)
                    .tint(challenge.changedFrom == nil ? Theme.green : Theme.danger)
            }
            Spacer()
        }
        .padding(24)
        .dtBackground()
        .interactiveDismissDisabled()
    }
}
