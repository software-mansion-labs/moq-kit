import Foundation
import SwiftUI

struct BoyGame: Identifiable, Hashable {
    let name: String
    let broadcastPath: String
    let viewerPathComponent: String

    var id: String { broadcastPath }
}

enum BoyControl: String {
    case up
    case down
    case left
    case right
    case a
    case b
    case start
    case select
}

enum BoyButton: String, Encodable {
    case up
    case down
    case left
    case right
    case a
    case b
    case start
    case select
}

struct BoyTimestamp: Encodable {
    let label: String
    let ts: Double
}

struct BoyButtonsCommand: Encodable {
    let buttons: [BoyButton]
    let timestamps: [BoyTimestamp]
}

struct BoyResetCommand: Encodable {}

enum BoyCommand: Encodable {
    case buttons(BoyButtonsCommand)
    case reset(BoyResetCommand)

    private enum CodingKeys: String, CodingKey {
        case type
        case buttons
        case timestamps
    }

    private enum CommandType: String, Encodable {
        case buttons
        case reset
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .buttons(let command):
            try container.encode(CommandType.buttons, forKey: .type)
            try container.encode(command.buttons, forKey: .buttons)
            try container.encode(command.timestamps, forKey: .timestamps)
        case .reset:
            try container.encode(CommandType.reset, forKey: .type)
        }
    }
}

extension BoyControl {
    var commandButton: BoyButton {
        switch self {
        case .up:
            return .up
        case .down:
            return .down
        case .left:
            return .left
        case .right:
            return .right
        case .a:
            return .a
        case .b:
            return .b
        case .start:
            return .start
        case .select:
            return .select
        }
    }
}

struct BoyScreenCopy {
    let title: String
    let subtitle: String
}

extension Color {
    static let boyShellTop = Color(red: 0.90, green: 0.88, blue: 0.79)
    static let boyShellBottom = Color(red: 0.82, green: 0.80, blue: 0.71)
    static let boyScreenBezel = Color(red: 0.24, green: 0.25, blue: 0.31)
    static let boyScreenFill = Color(red: 0.62, green: 0.71, blue: 0.47)
    static let boyScreenInk = Color(red: 0.15, green: 0.21, blue: 0.10)
    static let boyBrand = Color(red: 0.26, green: 0.22, blue: 0.45)
    static let boyLabel = Color(red: 0.20, green: 0.20, blue: 0.27)
    static let boyButtonTop = Color(red: 0.25, green: 0.27, blue: 0.31)
    static let boyButtonBottom = Color(red: 0.08, green: 0.09, blue: 0.11)
    static let boyButtonPressedTop = Color(red: 0.17, green: 0.18, blue: 0.21)
    static let boyButtonPressedBottom = Color(red: 0.04, green: 0.05, blue: 0.07)
    static let boyActionTop = Color(red: 0.52, green: 0.18, blue: 0.31)
    static let boyActionBottom = Color(red: 0.31, green: 0.08, blue: 0.17)
    static let boyActionPressedTop = Color(red: 0.39, green: 0.10, blue: 0.22)
    static let boyActionPressedBottom = Color(red: 0.22, green: 0.05, blue: 0.12)
    static let boyActionDisabledTop = Color(red: 0.39, green: 0.26, blue: 0.30)
    static let boyActionDisabledBottom = Color(red: 0.24, green: 0.16, blue: 0.20)
    static let boyActionLabel = Color(red: 0.23, green: 0.19, blue: 0.34)
    static let boyIndicator = Color(red: 0.75, green: 0.10, blue: 0.21)
}
