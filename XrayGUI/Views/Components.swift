import SwiftUI

// MARK: - Shared design-system components used across all views.
// Views must reuse these rather than redefining their own, to avoid duplicate
// top-level declarations and keep a consistent look.

/// A compact icon button with a tooltip, used for row actions.
struct IconButton: View {
    let icon: String
    let tooltip: String
    let color: Color
    let action: () -> Void

    init(_ icon: String, tooltip: String, color: Color = .secondary, action: @escaping () -> Void) {
        self.icon = icon
        self.tooltip = tooltip
        self.color = color
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 28, height: 28)
                .background(Color.secondary.opacity(0.08))
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }
}

/// A titled, rounded card container.
struct Card<Content: View>: View {
    let title: String?
    let systemImage: String?
    @ViewBuilder var content: () -> Content

    init(_ title: String? = nil, systemImage: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content
    }

    var body: some View {
        GroupBox {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
        } label: {
            if let title {
                Label(title.localized, systemImage: systemImage ?? "circle.fill")
            }
        }
    }
}

/// A small labelled statistic tile (used for traffic / latency / counts).
struct StatTile: View {
    let label: String
    let value: String
    var systemImage: String? = nil
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage).font(.caption2).foregroundStyle(.secondary)
                }
                Text(label.localized).font(.caption2).foregroundStyle(.secondary)
            }
            Text(value).font(.system(.title3, design: .rounded).weight(.semibold)).foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(8)
    }
}

/// A pill / badge.
struct Badge: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}

/// Renders a `LatencyResult` as a coloured badge.
struct LatencyBadge: View {
    let result: LatencyResult?

    var body: some View {
        switch result {
        case .some(.testing):
            ProgressView().controlSize(.mini)
        case .some(.ms(let v)):
            Badge(text: "\(v) ms", color: color(for: v))
        case .some(.failed):
            Badge(text: "timeout".localized, color: .red)
        default:
            Badge(text: "—", color: .secondary)
        }
    }

    private func color(for ms: Int) -> Color {
        switch ms {
        case ..<200: return .green
        case ..<500: return .orange
        default: return .red
        }
    }
}

/// Badge for a node's measured download speed (Mbps). Renders nothing until a test
/// has been run, so rows stay uncluttered.
struct SpeedBadge: View {
    let result: SpeedResult?

    var body: some View {
        switch result {
        case .some(.testing):
            ProgressView().controlSize(.mini)
        case .some(.mbps(let v)):
            Badge(text: String(format: "%.1f Mbps", v), color: color(for: v))
        case .some(.failed):
            Badge(text: "failed".localized, color: .red)
        default:
            EmptyView()
        }
    }

    private func color(for mbps: Double) -> Color {
        switch mbps {
        case 20...: return .green
        case 5 ..< 20: return .orange
        default: return .red
        }
    }
}

/// A centered empty-state placeholder with an optional primary action.
struct EmptyState: View {
    let icon: String
    let title: String
    let subtitle: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
            Text(title.localized).font(.title2.bold())
            Text(subtitle.localized)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle.localized, action: action)
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

// MARK: - Formatting helpers

enum Format {
    /// Human-readable byte count, e.g. "1.2 MB".
    static func bytes(_ value: Int64) -> String {
        let bcf = ByteCountFormatter()
        bcf.countStyle = .binary
        bcf.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return bcf.string(fromByteCount: max(0, value))
    }

    /// Human-readable transfer rate, e.g. "1.2 MB/s".
    static func speed(_ bytesPerSecond: Int64) -> String {
        bytes(bytesPerSecond) + "/s"
    }

    /// A relative "x ago" / absolute date string for subscription timestamps.
    static func date(_ date: Date?) -> String {
        guard let date else { return "—" }
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: date)
    }
}
