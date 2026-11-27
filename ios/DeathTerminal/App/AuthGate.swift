import SwiftUI

/// Hook for the required account sign-in.
///
/// Everything in the app is wrapped in `AuthGate`. Right now it passes straight
/// through to its content. The email/password accounts work replaces the body
/// with: show a sign-in / create-account screen until the user is signed in,
/// then show `content`.
struct AuthGate<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
    }
}
