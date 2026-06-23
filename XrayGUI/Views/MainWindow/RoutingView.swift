import SwiftUI

/// The routing settings screen: mode preset, general options, DNS servers and
/// user-authored custom rules. Bound entirely to `appState.routing`.
struct RoutingView: View {
    @EnvironmentObject var appState: AppState

    /// Index into `appState.routing.customRules` currently being edited, if any.
    @State private var editingRuleID: RoutingRule.ID?

    /// The strategy group currently being edited in a sheet, if any.
    @State private var editingGroup: NodeGroup?

    private let domainStrategies = ["AsIs", "IPIfNonMatch", "IPOnDemand"]
    private let networks = ["", "tcp", "udp", "tcp,udp"]

    var body: some View {
        Form {
            Section("Routing Mode".localized) {
                Picker("Mode".localized, selection: $appState.routing.mode) {
                    ForEach(RoutingMode.allCases) { mode in
                        Text(label(for: mode)).tag(mode)
                    }
                }
                .pickerStyle(.menu)
            }

            Section("General".localized) {
                Toggle("Bypass LAN".localized, isOn: $appState.routing.bypassLAN)
                Toggle("Block Ads".localized, isOn: $appState.routing.blockAds)
                Picker("Domain Strategy".localized, selection: $appState.routing.domainStrategy) {
                    ForEach(domainStrategies, id: \.self) { strategy in
                        Text(strategy).tag(strategy)
                    }
                }
                .pickerStyle(.menu)
            }

            Section("DNS".localized) {
                Toggle("Enable DNS".localized, isOn: $appState.routing.enableDNS)
                DNSListEditor(title: "Remote DNS", servers: $appState.routing.remoteDNS)
                DNSListEditor(title: "Direct DNS", servers: $appState.routing.directDNS)
            }
            .disabled(!appState.routing.enableDNS)

            Section {
                if appState.nodeGroups.isEmpty {
                    Text("No strategy groups yet.".localized)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appState.nodeGroups) { group in
                        StrategyGroupRow(
                            group: group,
                            memberCount: appState.groupMembers(group).count,
                            isSelected: appState.selectedGroupId == group.id,
                            onSelect: { appState.selectGroup(group.id) },
                            onEdit: { editingGroup = group },
                            onDelete: { appState.removeGroup(group.id) }
                        )
                    }
                }
            } header: {
                HStack {
                    Text("Strategy Groups (Balancer)".localized)
                    Spacer()
                    Button {
                        addGroup()
                    } label: {
                        Label("New Group".localized, systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                    .disabled(appState.nodes.isEmpty)
                }
            } footer: {
                Text("Load-balance across multiple nodes using Xray's balancer (leastPing / leastLoad / random).".localized)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section {
                if appState.routing.customRules.isEmpty {
                    Text("No custom rules yet.".localized)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach($appState.routing.customRules) { $rule in
                        RoutingRuleRow(
                            rule: $rule,
                            onEdit: { editingRuleID = rule.id },
                            onDelete: { delete(rule.id) }
                        )
                    }
                    .onMove { from, to in
                        appState.routing.customRules.move(fromOffsets: from, toOffset: to)
                    }
                }
            } header: {
                HStack {
                    Text("Custom Rules".localized)
                    Spacer()
                    Button {
                        addRule()
                    } label: {
                        Label("Add Rule".localized, systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                }
            } footer: {
                if !appState.routing.customRules.isEmpty {
                    Text("Drag to reorder rules.".localized)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .sheet(item: editingRuleBinding) { idBox in
            if let binding = binding(for: idBox.id) {
                RoutingRuleEditorSheet(rule: binding)
            }
        }
        .sheet(item: $editingGroup) { group in
            StrategyGroupEditorSheet(
                group: group,
                nodes: appState.nodes,
                onSave: { saveGroup($0) }
            )
        }
    }

    // MARK: - Strategy group mutation

    private func addGroup() {
        editingGroup = NodeGroup(name: "")
    }

    /// Persist a created or edited group back into `AppState`.
    private func saveGroup(_ group: NodeGroup) {
        if appState.nodeGroups.contains(where: { $0.id == group.id }) {
            appState.updateGroup(group)
        } else {
            appState.addGroup(group)
        }
    }

    // MARK: - Mode labels

    private func label(for mode: RoutingMode) -> String {
        switch mode {
        case .global: return "Global".localized
        case .bypassMainland: return "Bypass Mainland China".localized
        case .directMainlandProxyRest: return "Direct (proxy custom only)".localized
        case .direct: return "Direct".localized
        case .custom: return "Custom".localized
        }
    }

    // MARK: - Rule mutation

    private func addRule() {
        let rule = RoutingRule()
        appState.routing.customRules.append(rule)
        editingRuleID = rule.id
    }

    private func delete(_ id: RoutingRule.ID) {
        appState.routing.customRules.removeAll { $0.id == id }
        if editingRuleID == id { editingRuleID = nil }
    }

    private func binding(for id: RoutingRule.ID) -> Binding<RoutingRule>? {
        guard let index = appState.routing.customRules.firstIndex(where: { $0.id == id }) else { return nil }
        return $appState.routing.customRules[index]
    }

    /// Wraps `editingRuleID` as an `Identifiable` item binding for `.sheet(item:)`.
    private var editingRuleBinding: Binding<IdentifiedID?> {
        Binding(
            get: { editingRuleID.map(IdentifiedID.init) },
            set: { editingRuleID = $0?.id }
        )
    }

    /// Small `Identifiable` wrapper so the rule id can drive `.sheet(item:)`.
    private struct IdentifiedID: Identifiable {
        let id: RoutingRule.ID
    }
}

// MARK: - Custom rule row

/// A single row in the custom-rules list showing a summary, outbound badge and
/// enable / edit / delete controls.
struct RoutingRuleRow: View {
    @Binding var rule: RoutingRule
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: $rule.enabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)

            VStack(alignment: .leading, spacing: 2) {
                Text(primaryText)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                if !secondaryText.isEmpty {
                    Text(secondaryText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Badge(text: rule.outbound.rawValue, color: badgeColor)

            IconButton("pencil", tooltip: "Edit".localized, action: onEdit)
            IconButton("trash", tooltip: "Delete".localized, color: .red, action: onDelete)
        }
        .opacity(rule.enabled ? 1 : 0.5)
    }

    private var primaryText: String {
        if !rule.remark.isEmpty { return rule.remark }
        if let first = rule.domains.first(where: { !$0.isEmpty }) { return first }
        if let first = rule.ips.first(where: { !$0.isEmpty }) { return first }
        return "Untitled rule".localized
    }

    private var secondaryText: String {
        var parts: [String] = []
        if !rule.domains.isEmpty { parts.append("\(rule.domains.count) " + "domains".localized) }
        if !rule.ips.isEmpty { parts.append("\(rule.ips.count) " + "IPs".localized) }
        if !rule.port.isEmpty { parts.append("port".localized + " " + rule.port) }
        if !rule.network.isEmpty { parts.append(rule.network) }
        return parts.joined(separator: " · ")
    }

    private var badgeColor: Color {
        switch rule.outbound {
        case .proxy: return .blue
        case .direct: return .green
        case .block: return .red
        }
    }
}

// MARK: - Rule editor sheet

/// A modal editor for a single `RoutingRule`. Domains and IPs are edited as
/// free-form text split on newlines and commas.
struct RoutingRuleEditorSheet: View {
    @Binding var rule: RoutingRule
    @Environment(\.dismiss) private var dismiss

    private let networks = ["", "tcp", "udp", "tcp,udp"]

    /// Common domain matchers offered as one-tap suggestions below the editor.
    private let commonDomains = [
        "geosite:cn",
        "geosite:geolocation-!cn",
        "geosite:google",
        "geosite:telegram",
        "geosite:netflix",
        "geosite:youtube",
        "geosite:category-ads-all",
        "domain:example.com"
    ]

    /// Common IP matchers offered as one-tap suggestions below the editor.
    private let commonIPs = [
        "geoip:cn",
        "geoip:private",
        "geoip:telegram",
        "geoip:google",
        "1.2.3.0/24"
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Edit Rule".localized).font(.headline)
                Spacer()
            }
            .padding()

            Divider()

            Form {
                Section {
                    TextField("Remark".localized, text: $rule.remark)
                    Picker("Outbound".localized, selection: $rule.outbound) {
                        ForEach(RuleOutbound.allCases) { outbound in
                            Text(outbound.rawValue.capitalized.localized).tag(outbound)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Domains".localized) {
                    TextEditor(text: domainsBinding)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 70)
                    Text("One matcher per line (e.g. geosite:cn, domain:example.com).".localized)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    matcherSuggestions(commonDomains) { appendDomain($0) }
                }

                Section("IPs".localized) {
                    TextEditor(text: ipsBinding)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 70)
                    Text("One matcher per line (e.g. geoip:cn, 1.2.3.0/24).".localized)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    matcherSuggestions(commonIPs) { appendIP($0) }
                }

                Section {
                    TextField("Port".localized, text: $rule.port)
                    Picker("Network".localized, selection: $rule.network) {
                        ForEach(networks, id: \.self) { net in
                            Text(net.isEmpty ? "Any".localized : net).tag(net)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Done".localized) { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(width: 440, height: 560)
    }

    /// A horizontally scrolling row of one-tap matcher chips. Tapping a chip
    /// invokes `action` with that matcher so it can be appended to a list.
    private func matcherSuggestions(_ matchers: [String], action: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Tap to add a common matcher".localized)
                .font(.caption2)
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(matchers, id: \.self) { matcher in
                        Button(matcher) { action(matcher) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .font(.caption2)
                    }
                }
            }
        }
    }

    /// Appends a matcher to the rule's domain list, skipping duplicates.
    private func appendDomain(_ matcher: String) {
        if !rule.domains.contains(matcher) { rule.domains.append(matcher) }
    }

    /// Appends a matcher to the rule's IP list, skipping duplicates.
    private func appendIP(_ matcher: String) {
        if !rule.ips.contains(matcher) { rule.ips.append(matcher) }
    }

    private var domainsBinding: Binding<String> {
        Binding(
            get: { rule.domains.joined(separator: "\n") },
            set: { rule.domains = Self.tokenize($0) }
        )
    }

    private var ipsBinding: Binding<String> {
        Binding(
            get: { rule.ips.joined(separator: "\n") },
            set: { rule.ips = Self.tokenize($0) }
        )
    }

    /// Splits free-form input on newlines and commas, trimming and dropping blanks.
    private static func tokenize(_ text: String) -> [String] {
        text
            .split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

// MARK: - Strategy group row

/// A single row in the strategy-groups list showing the group name, its strategy
/// badge and member count, plus selection / edit / delete controls. Selecting a row
/// makes the group the active balancer outbound source.
struct StrategyGroupRow: View {
    let group: NodeGroup
    let memberCount: Int
    let isSelected: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .onTapGesture(perform: onSelect)

            VStack(alignment: .leading, spacing: 2) {
                Text(group.name.isEmpty ? "Untitled group".localized : group.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text("\(memberCount) " + "members".localized)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Badge(text: group.strategy.displayKey.localized, color: .purple)

            IconButton("pencil", tooltip: "Edit".localized, action: onEdit)
            IconButton("trash", tooltip: "Delete".localized, color: .red, action: onDelete)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}

// MARK: - Strategy group editor sheet

/// A modal editor for a `NodeGroup`: name, balancer strategy, member selection (a
/// toggle list over all known nodes) and — for observatory-driven strategies — the
/// probe URL and interval. Calls `onSave` with the assembled group on confirmation.
struct StrategyGroupEditorSheet: View {
    @State var group: NodeGroup
    let nodes: [ProxyNode]
    let onSave: (NodeGroup) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Edit Strategy Group".localized).font(.headline)
                Spacer()
            }
            .padding()

            Divider()

            Form {
                Section {
                    TextField("Name".localized, text: $group.name)
                    Picker("Strategy".localized, selection: $group.strategy) {
                        ForEach(BalancerStrategy.allCases) { strategy in
                            Text(strategy.displayKey.localized).tag(strategy)
                        }
                    }
                    .pickerStyle(.menu)
                }

                if group.strategy.needsObservatory {
                    Section("Health Check".localized) {
                        TextField("Probe URL".localized, text: $group.probeURL)
                        TextField("Probe Interval".localized, text: $group.probeInterval)
                    }
                }

                Section("Members".localized) {
                    if nodes.isEmpty {
                        Text("No nodes available.".localized)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(nodes) { node in
                            Toggle(isOn: memberBinding(node.id)) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(node.name)
                                        .font(.callout)
                                        .lineLimit(1)
                                    Text("\(node.address):\(node.port)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel".localized) { dismiss() }
                Button("Done".localized) {
                    onSave(group)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(group.name.trimmingCharacters(in: .whitespaces).isEmpty || group.memberIds.isEmpty)
            }
            .padding()
        }
        .frame(width: 440, height: 560)
    }

    /// A binding that toggles a node's membership in the group, preserving order.
    private func memberBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { group.memberIds.contains(id) },
            set: { isMember in
                if isMember {
                    if !group.memberIds.contains(id) { group.memberIds.append(id) }
                } else {
                    group.memberIds.removeAll { $0 == id }
                }
            }
        )
    }
}

// MARK: - DNS list editor

/// A minimal editor for a list of DNS server strings: shows each entry with a
/// delete button and a text field + add button to append new ones.
struct DNSListEditor: View {
    let title: String
    @Binding var servers: [String]

    @State private var newServer: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.localized)
                .font(.callout.weight(.medium))

            if servers.isEmpty {
                Text("No servers.".localized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(servers.enumerated()), id: \.offset) { index, server in
                    HStack(spacing: 8) {
                        Image(systemName: "server.rack")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(server)
                            .font(.system(.body, design: .monospaced))
                        Spacer()
                        IconButton("trash", tooltip: "Delete".localized, color: .red) {
                            remove(at: index)
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                TextField("Add server".localized, text: $newServer)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                IconButton("plus", tooltip: "Add".localized, color: .accentColor, action: add)
            }
        }
        .padding(.vertical, 2)
    }

    private func add() {
        let trimmed = newServer.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        servers.append(trimmed)
        newServer = ""
    }

    private func remove(at index: Int) {
        guard servers.indices.contains(index) else { return }
        servers.remove(at: index)
    }
}
