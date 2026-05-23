import Foundation
import SwiftUI

struct LogEntry: Identifiable {
    let id = UUID()
    let timestamp = Date()
    let message: String
    let level: Level

    enum Level: String, CaseIterable {
        case debug, info, warning, error

        var color: Color {
            switch self {
            case .debug: return .secondary
            case .info: return .primary
            case .warning: return .orange
            case .error: return .red
            }
        }

        var icon: String {
            switch self {
            case .debug: return "magnifyingglass"
            case .info: return "info.circle"
            case .warning: return "exclamationmark.triangle"
            case .error: return "xmark.circle"
            }
        }
    }

    var formattedTime: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: timestamp)
    }
}
