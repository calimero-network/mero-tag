import SwiftUI

/// After sign-in: open the space (context) to share locations in, and pick
/// the name other members see.
struct SpaceSetupView: View {
    @EnvironmentObject private var app: AppState
    @State private var contextId = ""
    @State private var displayName = ""
    @State private var confirmSignOut = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Cal.Space.stack) {
                    PageHeader(
                        title: "Open a space",
                        subtitle: "A space is the group you share locations with. Paste the space ID the owner sent you.")

                    if app.client.isSignedInWithoutRelay {
                        Callout(
                            tone: .warning, title: "No relay yet",
                            message: "Your account isn't served by a relay yet. It gets one when you accept an "
                                + "invitation to a space.")
                    }

                    Card {
                        VStack(alignment: .leading, spacing: 20) {
                            CalTextField(
                                label: "Space ID", placeholder: "Paste the space ID", text: $contextId,
                                help: "Also called the context ID.", monospaced: true,
                                keyboardKind: .identifier, submitLabel: .next)
                                .accessibilityIdentifier("spaceIdField")

                            CalTextField(
                                label: "Your name", placeholder: "e.g. Ana", text: $displayName,
                                help: "Shown to the other members of this space.",
                                submitLabel: .go, onSubmit: open)
                                .accessibilityIdentifier("displayNameField")

                            if let error = app.spaceError {
                                Callout(tone: .danger, message: error)
                                    .accessibilityIdentifier("spaceError")
                            }

                            LoadingButton(
                                title: "Open space", systemImage: "arrow.right",
                                isLoading: app.isOpeningSpace, action: open)
                                .disabled(contextId.isEmpty || displayName.isEmpty)
                                .accessibilityIdentifier("openSpaceButton")

                            TechnicalDetails(items: AccountDetails.items(app))
                        }
                    }
                }
                .calPage()
            }
            .background(Cal.bg.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .calLeading) { BrandTitle() }
                ToolbarItem(placement: .calTrailing) {
                    Button("Sign out") { confirmSignOut = true }
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Cal.textDim)
                }
            }
            .inlineNavigationTitle()
            .calNavigationBar()
            .confirmationDialog("Sign out of Mero Tag?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) { Task { await app.signOut() } }
            }
        }
        .onAppear {
            if contextId.isEmpty { contextId = app.space?.contextId ?? "" }
            if displayName.isEmpty { displayName = app.space?.displayName ?? "" }
        }
    }

    private func open() {
        Task { await app.openSpace(contextId: contextId, displayName: displayName) }
    }
}

/// The account/session values worth showing behind "Show technical details".
enum AccountDetails {
    @MainActor
    static func items(_ app: AppState, contextId: String? = nil) -> [DetailItem] {
        var items: [DetailItem] = []
        if let contextId { items.append(DetailItem(label: "Space (context) ID", value: contextId)) }
        if let account = app.client.account { items.append(DetailItem(label: "Account", value: account)) }
        if let device = app.client.connection?.session.device {
            items.append(DetailItem(label: "Device", value: device))
        }
        if let relay = app.client.relayURL { items.append(DetailItem(label: "Relay", value: relay)) }
        if let key = app.client.connection?.nodeKey { items.append(DetailItem(label: "Relay node key", value: key)) }
        if let note = app.client.cloudNote { items.append(DetailItem(label: "Session note", value: note, copyable: false)) }
        return items
    }
}
