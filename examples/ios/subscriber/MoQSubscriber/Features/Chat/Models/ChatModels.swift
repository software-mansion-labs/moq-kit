import Foundation

struct ChatPayload: Codable, Equatable {
    let from: String
    let message: String
}

struct ChatMessage: Identifiable, Equatable {
    enum Direction: Equatable {
        case local
        case remote
    }

    let id = UUID()
    let direction: Direction
    let from: String
    let text: String
    let broadcastPath: String
    let timestamp: Date

    var isLocal: Bool {
        direction == .local
    }
}

