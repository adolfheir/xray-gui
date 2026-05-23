import Foundation

struct Profile: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var configPath: String
    var createdAt: Date = Date()

    var configURL: URL { URL(fileURLWithPath: configPath) }

    var exists: Bool { FileManager.default.fileExists(atPath: configPath) }

    var fileName: String { configURL.lastPathComponent }
}
