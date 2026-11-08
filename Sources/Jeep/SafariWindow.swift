import Foundation

struct SafariWindow: Identifiable, Equatable, Codable {
    let id: Int
    let title: String
    let isVisible: Bool
    let bounds: CGRect
    /// A verified native Safari profile name, never a page-title inference.
    var profileName: String? = nil

    var nativeLabel: String {
        profileName ?? "Safari window \(id)"
    }
}
