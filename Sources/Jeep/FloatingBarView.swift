import AppKit
import SwiftUI

@MainActor
final class FloatingBarContentStore: ObservableObject {
    @Published private(set) var snapshot = FloatingBarContentSnapshot.empty
    @Published private(set) var orientation = FloatingBarOrientation.horizontal
    /// The vertical rail (the bar over Safari's page) shows only the Jeep
    /// until the pointer hovers it. Ignored for the horizontal bar.
    @Published private(set) var railIsFolded = true
    /// Unfolds the rail without a pointer, for VoiceOver and keyboard users.
    /// Set by the bar's controller.
    var revealRail: (() -> Void)?

    func apply(
        _ snapshot: FloatingBarContentSnapshot,
        orientation: FloatingBarOrientation = .horizontal
    ) {
        if self.orientation != orientation {
            self.orientation = orientation
        }
        if self.snapshot != snapshot {
            self.snapshot = snapshot
        }
    }

    func setRailFolded(_ folded: Bool) {
        if railIsFolded != folded {
            railIsFolded = folded
        }
    }
}

/// Spacing and sizes on the 4/8-point grid. The bar's outer size comes from
/// `FloatingBarGeometryPolicy`; these fit inside it in both orientations.
private enum FloatingBarMetrics {
    static let outerInset: CGFloat = 4
    static let railPadding: CGFloat = 8
    static let sectionSpacing: CGFloat = 8
    static let profileSpacing: CGFloat = 4
    static let markSize: CGFloat = 32
    static let separatorLength: CGFloat = 24
    static let cellSize: CGFloat = 32
    static let chipSize: CGFloat = 24
    static let cornerRadius: CGFloat = 16
    /// The folded rail's rounded square, inside the panel's inset.
    static let railFoldedSide = FloatingBarRailFoldPolicy.foldedSide - 2 * outerInset
    /// The rail keeps the Jeep centered in that square, folded or not, so
    /// the Jeep stays put while the rail unfolds below it.
    static let railMarkInset = (railFoldedSide - markSize) / 2
}

/// How the rail unfolds and folds. The panel holds the full rail's frame for
/// the whole motion (`FloatingBarRailFoldPolicy`), so only drawing changes.
private enum RailMotion {
    static let unfold = Animation.spring(duration: 0.35, bounce: 0.15)
    static let fold = Animation.easeInOut(duration: FloatingBarRailFoldPolicy.foldAnimationDuration)
    /// Reduce Motion replaces growth and slides with this cross-fade.
    static let crossFade = Animation.easeInOut(duration: 0.15)
    /// Delay between the separator and each profile sliding in.
    static let stagger: Double = 0.03
    static let slideDistance: CGFloat = 8

    /// Folding, the separator and profiles fade out quickly, all at once.
    /// Unfolding, each one enters on its own (`RailEntrance`).
    static var contentTransition: AnyTransition {
        .asymmetric(insertion: .identity, removal: .opacity.animation(.easeOut(duration: 0.1)))
    }

    static func rail(folding: Bool, reduceMotion: Bool) -> Animation {
        if reduceMotion { return crossFade }
        return folding ? fold : unfold
    }

    static func entrance(order: Int, reduceMotion: Bool) -> Animation {
        reduceMotion ? crossFade : unfold.delay(Double(order) * stagger)
    }
}

struct FloatingBarView: View {
    @ObservedObject var model: SwitcherModel
    @ObservedObject var contentStore: FloatingBarContentStore
    /// The Jeep window this bar belongs to.
    let groupID: UUID
    var brandImage = AppBrand.floatingBarImage()
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    /// How far the rail is drawn unfolded: 0 is the Jeep's square, 1 the
    /// whole panel. It follows `railIsFolded` in its own animated update, so
    /// a panel resize in the same pass as the fold change is never animated.
    @State private var railRevealState: CGFloat?

    var body: some View {
        let styles = ProfilePresentationPolicy.WindowStyles(windows: styledWindows)
        barLayout {
            appMark

            // Folded, the rail is just the Jeep. The mark stays the first
            // child either way, so its menu and focus survive unfolding.
            if !isRailFolded {
                Rectangle()
                    .fill(isVertical ? Color.white.opacity(0.45) : Color(nsColor: .tertiaryLabelColor))
                    .frame(
                        width: isVertical ? FloatingBarMetrics.separatorLength : 1,
                        height: isVertical ? 1 : FloatingBarMetrics.separatorLength
                    )
                    .accessibilityHidden(true)
                    .modifier(RailEntrance(order: 0, isOnRail: isVertical))
                    .transition(RailMotion.contentTransition)

                ScrollViewReader { proxy in
                    ScrollView(isVertical ? .vertical : .horizontal, showsIndicators: false) {
                        profileLayout {
                            ForEach(Array(contentStore.snapshot.windows.enumerated()), id: \.element.id) { index, window in
                                profileButton(for: window, styles: styles)
                                    .modifier(RailEntrance(order: index + 1, isOnRail: isVertical))
                                    .id(window.id)
                            }
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Safari profiles")
                    .onGeometryChange(for: CGFloat.self) { geometry in
                        isVertical ? geometry.size.height : geometry.size.width
                    } action: { _ in
                        revealSelection(using: proxy)
                    }
                    .onChange(of: selectedProfileID, initial: true) { _, _ in
                        revealSelection(using: proxy)
                    }
                    .onChange(of: contentStore.orientation) { _, _ in
                        revealSelection(using: proxy)
                    }
                    .onChange(of: contentStore.snapshot.windows.count) { _, _ in
                        revealSelection(using: proxy)
                    }
                }
                .transition(RailMotion.contentTransition)
            }
        }
        .padding(barContentInsets)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: isVertical ? .top : .center)
        // The profiles show only inside the rail as it grows.
        .mask { contentMask }
        .background {
            barBackground
                // Fits inside the panel's transparent inset, so it separates
                // the bar from page content without widening its hit area.
                .shadow(color: .black.opacity(0.18), radius: 2, x: 0, y: 1)
        }
        .overlay { barBorder }
        .padding(FloatingBarMetrics.outerInset)
        .onAppear {
            if railRevealState == nil {
                railRevealState = contentStore.railIsFolded ? 0 : 1
            }
        }
        .onChange(of: contentStore.railIsFolded) { _, folded in
            withAnimation(RailMotion.rail(folding: folded, reduceMotion: reduceMotion)) {
                railRevealState = folded ? 0 : 1
            }
        }
    }

    /// Folded, the rail draws only its top square, whatever the panel's
    /// height; Reduce Motion fades the rest of the rail instead of growing it.
    @ViewBuilder
    private var barBackground: some View {
        if isVertical && reduceMotion {
            ZStack {
                barFill(BarShape(revealed: 0))
                barFill(BarShape(revealed: 1, excludesFoldedSquare: true))
                    .opacity(railReveal)
            }
        } else {
            barFill(barShape)
        }
    }

    /// The horizontal bar is plain material. The vertical rail sits over the
    /// page, so it is blue-tinted glass that reads as Jeep's, not the page's.
    @ViewBuilder
    private func barFill(_ shape: BarShape) -> some View {
        if !isVertical {
            shape
                .fill(reduceTransparency
                    ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor))
                    : AnyShapeStyle(.regularMaterial))
        } else if reduceTransparency {
            shape.fill(Color(nsColor: .systemBlue))
        } else {
            shape
                .fill(.regularMaterial)
                .overlay {
                    shape.fill(Color(nsColor: .systemBlue).opacity(0.6))
                }
        }
    }

    @ViewBuilder
    private var barBorder: some View {
        let color = isVertical ? Color.white.opacity(0.25) : Color(nsColor: .separatorColor)
        if isVertical && reduceMotion {
            ZStack {
                BarShape(revealed: 0)
                    .strokeBorder(color, lineWidth: 0.5)
                    .opacity(1 - railReveal)
                BarShape(revealed: 1)
                    .strokeBorder(color, lineWidth: 0.5)
                    .opacity(railReveal)
            }
        } else {
            barShape.strokeBorder(color, lineWidth: 0.5)
        }
    }

    @ViewBuilder
    private var contentMask: some View {
        if isVertical {
            BarShape(revealed: reduceMotion ? 1 : railReveal)
        } else {
            Rectangle()
        }
    }

    /// The rail pins the Jeep to the top of the panel; the horizontal bar
    /// centers its row.
    private var barContentInsets: EdgeInsets {
        guard isVertical else {
            return EdgeInsets(
                top: 0,
                leading: FloatingBarMetrics.railPadding,
                bottom: 0,
                trailing: FloatingBarMetrics.railPadding
            )
        }
        return EdgeInsets(
            top: FloatingBarMetrics.railMarkInset,
            leading: 0,
            bottom: isRailFolded ? 0 : FloatingBarMetrics.railPadding,
            trailing: 0
        )
    }

    private var isRailFolded: Bool {
        isVertical && contentStore.railIsFolded
    }

    private var railReveal: CGFloat {
        railRevealState ?? (contentStore.railIsFolded ? 0 : 1)
    }

    private var barShape: BarShape {
        BarShape(revealed: isVertical ? railReveal : 1)
    }

    private var isVertical: Bool {
        contentStore.orientation == .vertical
    }

    // AnyLayout retains the same profile buttons and controls while the
    // persistent panel changes shape, including an in-progress handoff.
    private var barLayout: AnyLayout {
        isVertical
            ? AnyLayout(VStackLayout(spacing: FloatingBarMetrics.sectionSpacing))
            : AnyLayout(HStackLayout(spacing: FloatingBarMetrics.sectionSpacing))
    }

    private var profileLayout: AnyLayout {
        isVertical
            ? AnyLayout(VStackLayout(spacing: FloatingBarMetrics.profileSpacing))
            : AnyLayout(HStackLayout(spacing: FloatingBarMetrics.profileSpacing))
    }

    private var appMark: some View {
        ZStack {
            if model.isBusy && !model.keepsFloatingBarVisibleDuringManagedSwitch {
                ProgressView()
                    .controlSize(.small)
                    .tint(isVertical ? .white : .secondary)
                    // The macOS spinner ignores tint; a dark scheme draws it
                    // light so it stays visible on the blue rail.
                    .environment(\.colorScheme, isVertical ? .dark : colorScheme)
            } else {
                Image(nsImage: brandImage)
                    .resizable()
                    .renderingMode(.original)
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(
                        width: FloatingBarMetrics.markSize,
                        height: FloatingBarMetrics.markSize,
                        alignment: .center
                    )
            }
        }
        .frame(width: FloatingBarMetrics.markSize, height: FloatingBarMetrics.markSize)
        .help(AppBrand.name)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Jeep — Safari profiles")
        .accessibilityActions {
            if isRailFolded {
                Button("Show Profiles") {
                    contentStore.revealRail?()
                }
            }
        }
        .modifier(MergeMenu(model: model, groupID: groupID))
    }

    /// Every Jeep window shares one palette, so a profile keeps its color and
    /// number in whichever bar it sits.
    private var styledWindows: [SafariWindow] {
        let all = model.allWindows
        let known = Set(all.map(\.id))
        return all + contentStore.snapshot.windows.filter { !known.contains($0.id) }
    }

    private var selectedProfileID: Int? {
        contentStore.snapshot.handoffTargetWindowID ?? contentStore.snapshot.activeWindowID
    }

    private func revealSelection(using proxy: ScrollViewProxy) {
        guard let selectedProfileID else { return }
        proxy.scrollTo(selectedProfileID, anchor: .center)
    }

    private func profileButton(for window: SafariWindow, styles: ProfilePresentationPolicy.WindowStyles) -> some View {
        let snapshot = contentStore.snapshot
        let isActive = window.id == snapshot.activeWindowID
        let isIncoming = window.id == snapshot.handoffTargetWindowID
        // The leased copy can trail a just-verified (or lost) native name;
        // name and color come from the model's current copy when it has one.
        let current = model.allWindows.first { $0.id == window.id } ?? window
        let presentation = styles.presentation(
            for: current,
            displayName: model.profileDisplayName(for: current)
        )

        return Button {
            model.switchToWindow(window)
        } label: {
            ProfileChip(
                presentation: presentation,
                isActive: isActive,
                isIncoming: isIncoming,
                onWhiteDisc: isVertical
            )
        }
        .buttonStyle(FloatingBarProfileButtonStyle(onRail: isVertical))
        // The custom style stays undimmed, but keyboard/VoiceOver activation
        // must agree with pointer input while a switch is busy.
        .disabled(model.isBusy)
        .contextMenu {
            Button {
                model.moveWindowToNewGroup(window)
            } label: {
                Label("Move to New Jeep Window", systemImage: "macwindow.badge.plus")
                    .labelStyle(.titleAndIcon)
            }
            .disabled(!model.canMoveWindowToNewGroup(window))

            // Closes the profile's Safari window and its tabs without
            // switching to it; a visible one hands its place to the next.
            Button {
                model.closeWindow(window)
            } label: {
                Label("Close Window", systemImage: "xmark.square")
                    .labelStyle(.titleAndIcon)
            }
            .disabled(!model.canCloseWindow(window))
        }
        .help(isIncoming ? presentation.name + " — opening…" : presentation.name)
        .accessibilityLabel(presentation.name)
        .accessibilityValue(isIncoming ? "Opening" : "")
        .accessibilityHint("Switches Safari to this profile")
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

/// Right-click on the Jeep logo: merge this Jeep window into another. Only
/// present while there is another Jeep window to merge into.
private struct MergeMenu: ViewModifier {
    @ObservedObject var model: SwitcherModel
    let groupID: UUID

    func body(content: Content) -> some View {
        let targets = model.groupIDs.filter { $0 != groupID }
        if targets.isEmpty {
            content
        } else {
            content.contextMenu {
                Menu("Merge Into") {
                    ForEach(targets, id: \.self) { target in
                        Button(model.groupDisplayName(target)) {
                            model.mergeGroup(groupID, into: target)
                        }
                    }
                }
                .disabled(!model.canEditGroups)
            }
        }
    }
}

/// One profile: a tinted chip with the profile's symbol or monogram. The
/// active profile is a solid chip inside a ring, so it is distinguishable by
/// shape as well as by color. On the blue rail each chip sits on a white
/// disc, so blue and purple profile colors stay readable.
private struct ProfileChip: View {
    let presentation: ProfilePresentation
    let isActive: Bool
    let isIncoming: Bool
    var onWhiteDisc = false

    var body: some View {
        let tint = ProfilePresentationPolicy.colors[presentation.colorIndex]
        // `.primary` is white in Dark Mode, which would vanish on the disc.
        let inactiveGlyph = onWhiteDisc ? Color.black.opacity(0.85) : Color.primary

        ZStack {
            if onWhiteDisc {
                Circle()
                    .fill(Color.white)
            }

            Circle()
                .fill(isActive ? tint : tint.opacity(0.24))
                .frame(width: FloatingBarMetrics.chipSize, height: FloatingBarMetrics.chipSize)

            if isActive {
                Circle()
                    .strokeBorder(tint, lineWidth: 2)
            }

            Group {
                if isIncoming {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.8)
                        .tint(isActive ? .white : tint)
                } else {
                    switch presentation.glyph {
                    case let .symbol(name):
                        Image(systemName: name)
                            .font(.system(size: 12, weight: .semibold))
                    case let .monogram(letter):
                        Text(letter)
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                    }
                }
            }
            .foregroundStyle(isActive ? Color.white : inactiveGlyph)
        }
        .frame(width: FloatingBarMetrics.cellSize, height: FloatingBarMetrics.cellSize)
        .contentShape(Circle())
    }
}

/// Hover highlight and pressed feedback without changing layout: a subtle
/// fill on hover, a quick scale-down and fade on press. On the rail the chip
/// fills its cell with a white disc, so hover dims the disc instead. Reduce
/// Motion keeps the feedback but drops the scale and the animation.
private struct FloatingBarProfileButtonStyle: ButtonStyle {
    var onRail = false

    func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration, onRail: onRail)
    }

    private struct StyledButton: View {
        let configuration: ButtonStyleConfiguration
        let onRail: Bool
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .background {
                    Circle()
                        .fill(Color.primary.opacity(isHovered && !onRail ? 0.08 : 0))
                }
                .overlay {
                    if onRail {
                        Circle()
                            .fill(Color.black.opacity(isHovered ? 0.12 : 0))
                            .allowsHitTesting(false)
                    }
                }
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
                .opacity(configuration.isPressed ? 0.8 : 1)
                .animation(
                    reduceMotion ? nil : .easeOut(duration: 0.12),
                    value: configuration.isPressed
                )
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovered)
                .onHover { isHovered = $0 }
        }
    }
}

/// The bar's rounded outline. The rail's outline runs down from the top a
/// `revealed` fraction of the way from the folded square to the full panel,
/// so animating `revealed` grows or retracts the rail under a fixed Jeep.
/// Fully revealed, it is the plain rounded bar.
private struct BarShape: InsettableShape {
    /// 0 is the folded square, 1 the whole bar. Clamped, so a spring's
    /// overshoot never draws past the panel.
    var revealed: CGFloat
    /// Only the part of the bar below the folded square, for Reduce Motion's
    /// cross-fade.
    var excludesFoldedSquare = false
    var insetAmount: CGFloat = 0

    var animatableData: CGFloat {
        get { revealed }
        set { revealed = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let bar = outline(in: rect, revealed: revealed)
        guard excludesFoldedSquare else { return bar }
        return bar.subtracting(outline(in: rect, revealed: 0))
    }

    func inset(by amount: CGFloat) -> BarShape {
        var shape = self
        shape.insetAmount += amount
        return shape
    }

    private func outline(in rect: CGRect, revealed: CGFloat) -> Path {
        let folded = min(FloatingBarMetrics.railFoldedSide, rect.height)
        let height = folded + (rect.height - folded) * min(max(revealed, 0), 1)
        let frame = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: height)
            .insetBy(dx: insetAmount, dy: insetAmount)
        return RoundedRectangle(
            cornerRadius: max(FloatingBarMetrics.cornerRadius - insetAmount, 0),
            style: .continuous
        )
        .path(in: frame)
    }
}

/// Unfolding, the separator and each profile slide down out of the Jeep and
/// fade in, top to bottom. Reduce Motion fades them in place, together. The
/// horizontal bar shows them as they are.
private struct RailEntrance: ViewModifier {
    let order: Int
    let isOnRail: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasEntered = false

    func body(content: Content) -> some View {
        let isWaiting = isOnRail && !hasEntered
        return content
            .opacity(isWaiting ? 0 : 1)
            .offset(y: isWaiting && !reduceMotion ? -RailMotion.slideDistance : 0)
            .onAppear {
                guard isOnRail else {
                    hasEntered = true
                    return
                }
                withAnimation(RailMotion.entrance(order: order, reduceMotion: reduceMotion)) {
                    hasEntered = true
                }
            }
    }
}
