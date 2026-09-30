import Foundation
import UIKit

struct DoodleDrawing: Identifiable, Hashable {
    let id: String
    let from: Participant
    let createdAt: Date
    let previewImage: UIImage?
    let hasPhoto: Bool

    enum Participant: String, Hashable {
        case you
        case partner
    }

    var relativeLabel: String {
        let seconds = max(0, Int(Date().timeIntervalSince(createdAt)))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86400)d"
    }
}
