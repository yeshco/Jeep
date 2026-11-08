import AppKit
import SwiftUI

struct ProfilePresentation: Equatable {
    enum Glyph: Equatable {
        case symbol(String)
        /// A short name monogram or an unidentified window's ordinal.
        case monogram(String)
    }

    /// The name shown to the user: the alias when set, else the profile name.
    let name: String
    let glyph: Glyph
    let colorIndex: Int
}

enum ProfilePresentationPolicy {
    /// Profile button tints. Each tint is dark enough in both appearances
    /// for a white glyph on the active fill to keep at least 3:1 contrast.
    static let palette: [NSColor] = [
        adaptive(light: (0.00, 0.40, 0.84), dark: (0.04, 0.42, 0.86)),  // blue
        adaptive(light: (0.53, 0.25, 0.75), dark: (0.55, 0.30, 0.78)),  // purple
        adaptive(light: (0.80, 0.15, 0.42), dark: (0.80, 0.20, 0.45)),  // pink
        adaptive(light: (0.72, 0.33, 0.00), dark: (0.74, 0.36, 0.02)),  // orange
        adaptive(light: (0.10, 0.50, 0.22), dark: (0.12, 0.52, 0.25)),  // green
        adaptive(light: (0.00, 0.45, 0.55), dark: (0.02, 0.47, 0.58)),  // teal
        adaptive(light: (0.30, 0.30, 0.78), dark: (0.36, 0.36, 0.82))   // indigo
    ]

    static let colors: [Color] = palette.map(Color.init(nsColor:))

    static var colorCount: Int {
        palette.count
    }

    /// One calculation per represented window list. Native names share a
    /// style; unnamed windows occupy separate slots after the named profiles.
    struct WindowStyles {
        private let profileColors: [String: Int]
        private let windowOrdinals: [Int: Int]

        init(windows: [SafariWindow]) {
            let names = Set(windows.lazy.compactMap(\.profileName)).sorted {
                let order = $0.caseInsensitiveCompare($1)
                return order == .orderedSame ? $0 < $1 : order == .orderedAscending
            }
            profileColors = Dictionary(uniqueKeysWithValues: names.enumerated().lazy.map { index, name in
                (name, names.count <= colorCount ? index : hashedColorIndex(for: name))
            })
            let unknownIDs = Set(windows.lazy.compactMap { $0.profileName == nil ? $0.id : nil }).sorted()
            windowOrdinals = Dictionary(uniqueKeysWithValues: unknownIDs.enumerated().lazy.map {
                ($0.element, $0.offset + 1)
            })
        }

        /// Expects a window from the list used to calculate these styles. A
        /// window from an older copy of that list (a name verified or lost
        /// since) still gets a stable style instead of trapping.
        func presentation(for window: SafariWindow, displayName: String) -> ProfilePresentation {
            if let name = window.profileName {
                return ProfilePresentation(
                    name: displayName,
                    glyph: glyph(for: displayName),
                    colorIndex: profileColors[name] ?? hashedColorIndex(for: name)
                )
            }
            let ordinal = windowOrdinals[window.id] ?? windowOrdinals.count + 1
            return ProfilePresentation(
                name: displayName,
                glyph: .monogram(String(ordinal)),
                colorIndex: (profileColors.count + ordinal - 1) % colorCount
            )
        }
    }

    typealias KeywordSymbols = [(keywords: Set<String>, symbol: String)]

    private static let keywordSymbols: KeywordSymbols = [
        (["study", "reading", "books"], "book.closed.fill"),
        (["media", "video", "movie", "music", "youtube"], "play.rectangle.fill"),
        (["work", "office", "business"], "briefcase.fill"),
        (["personal", "home", "family"], "house.fill"),
        (["social", "twitter", "facebook", "chat"], "bubble.left.and.bubble.right.fill"),
        (["finance", "bank", "trading", "stocks"], "chart.line.uptrend.xyaxis"),
        (["code", "dev", "github", "programming"], "chevron.left.forwardslash.chevron.right"),
        (["news"], "newspaper.fill"),
        (["shop", "shopping", "store"], "cart.fill"),
        (["travel", "trip"], "airplane"),
        (["school", "education", "learning"], "graduationcap.fill"),
        (["mail", "email"], "envelope.fill"),
        (["health", "fitness"], "heart.fill"),
        (["game", "gaming"], "gamecontroller.fill"),
        (["research", "search"], "magnifyingglass")
    ]

    private static let bundledKeywordSymbols = loadKeywordSymbols(
        from: Bundle.main.url(forResource: "IconKeywords.local", withExtension: "json")
    )

    static func loadKeywordSymbols(from localFileURL: URL?) -> KeywordSymbols {
        guard let localFileURL,
              let data = try? Data(contentsOf: localFileURL),
              let local = try? JSONDecoder().decode([String: String].self, from: data) else {
            return keywordSymbols
        }

        // Local matches win; sorting makes multiple local matches deterministic.
        let overrides: KeywordSymbols = local.keys.sorted().map { keyword in
            let normalized = keyword.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .lowercased()
            return (keywords: [normalized], symbol: local[keyword]!)
        }
        return overrides + keywordSymbols
    }

    /// A keyword symbol when one of the name's whole words names a topic,
    /// else the name's first letter.
    static func glyph(
        for name: String,
        keywordSymbols: KeywordSymbols = bundledKeywordSymbols
    ) -> ProfilePresentation.Glyph {
        let words = Set(
            name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
        )

        if let mapping = keywordSymbols.first(where: { !$0.keywords.isDisjoint(with: words) }) {
            return .symbol(mapping.symbol)
        }

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let initial = trimmed.first(where: { $0.isLetter || $0.isNumber }) ?? trimmed.first
        return initial.map { .monogram(String($0).uppercased()) } ?? .symbol("globe")
    }

    private static func hashedColorIndex(for profileName: String) -> Int {
        let scalarTotal = profileName.unicodeScalars.reduce(0) { partialResult, scalar in
            partialResult &+ Int(scalar.value)
        }
        return abs(scalarTotal) % colorCount
    }

    private static func adaptive(
        light: (CGFloat, CGFloat, CGFloat),
        dark: (CGFloat, CGFloat, CGFloat)
    ) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let (red, green, blue) = isDark ? dark : light
            return NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
        }
    }
}
