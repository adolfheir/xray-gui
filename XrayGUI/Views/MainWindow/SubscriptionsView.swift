import SwiftUI

/// Lists and manages remote subscriptions: add, update (single / all), delete,
/// and toggle per-subscription auto-update.
struct SubscriptionsView: View {
    @EnvironmentObject var appState: AppState
    @State private var showAddSheet = false

    var body: some View {
        Group {
            if appState.subscriptions.isEmpty {
                EmptyState(
                    icon: "antenna.radiowaves.left.and.right",
                    title: "No Subscriptions",
                    subtitle: "Add a subscription or import a share link to get started.",
                    actionTitle: "Add Subscription",
                    action: { showAddSheet = true }
                )
            } else {
                List {
                    ForEach($appState.subscriptions) { $subscription in
                        SubscriptionRow(subscription: $subscription)
                            .listRowSeparator(.visible)
                    }
                }
                .listStyle(.inset)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    showAddSheet = true
                } label: {
                    Label("Add".localized, systemImage: "plus")
                }
                Button {
                    Task { await appState.updateAllSubscriptions() }
                } label: {
                    Label("Update All".localized, systemImage: "arrow.clockwise")
                }
                .disabled(appState.subscriptions.isEmpty)
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddSubscriptionSheet()
                .environmentObject(appState)
        }
    }
}

/// A single subscription entry with metadata and inline actions.
struct SubscriptionRow: View {
    @EnvironmentObject var appState: AppState
    @Binding var subscription: Subscription

    private var autoUpdateBinding: Binding<Bool> {
        Binding(
            get: { subscription.autoUpdateHours > 0 },
            set: { newValue in
                if let idx = appState.subscriptions.firstIndex(where: { $0.id == subscription.id }) {
                    appState.subscriptions[idx].autoUpdateHours = newValue ? 24 : 0
                }
            }
        )
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(subscription.name)
                    .font(.headline)
                Text(subscription.url)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 8) {
                    Text("\(subscription.nodeCount) " + "Nodes".localized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("•").font(.caption).foregroundStyle(.secondary)
                    Text("Last updated".localized + ": " + Format.date(subscription.lastUpdated))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let total = subscription.totalTraffic {
                    Text(Format.bytes(subscription.usedTraffic ?? 0) + " / " + Format.bytes(total))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if let expire = subscription.expireDate {
                    Text("Expires".localized + ": " + Format.date(expire))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Toggle(isOn: autoUpdateBinding) {
                    Text("Auto Update".localized)
                        .font(.caption)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .padding(.top, 2)
            }

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                IconButton("arrow.clockwise", tooltip: "Update".localized) {
                    let id = subscription.id
                    Task { await appState.updateSubscription(id) }
                }
                IconButton("trash", tooltip: "Delete".localized, color: .red) {
                    appState.removeSubscription(subscription.id)
                }
            }
        }
        .padding(.vertical, 6)
    }
}

/// Modal sheet to add a new subscription by name + URL.
struct AddSubscriptionSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var url = ""

    private var trimmedURL: String {
        url.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Add Subscription".localized)
                .font(.title3.bold())
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 12)

            Form {
                TextField("Name".localized, text: $name)
                TextField("Subscription URL".localized, text: $url)
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel".localized) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add".localized) {
                    appState.addSubscription(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                             url: trimmedURL)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(trimmedURL.isEmpty)
            }
            .padding(20)
        }
        .frame(width: 460)
    }
}
