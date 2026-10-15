import AppKit
import SwiftUI

/// The material the notch status surface is painted with. Raw values are persistence keys, not
/// display copy: they stay stable so a label can change without losing a saved choice. The default
/// is `.glass`, so a surface nobody configured is not a black shape that is easy to lose.
///
/// Modeled on the surface styles of CodeNotch (MIT, github.com/vinzdg/codenotch), reimplemented
/// here: the pure resolution rules live on this enum so they are tested without a window.
enum NotchSurfaceStyle: String, CaseIterable, Identifiable {
    /// System Liquid Glass. The panel's appearance is left to the system, so it follows light and
    /// dark and the Clear or Tinted setting.
    case glass
    /// Clear Liquid Glass over a translucent black wash. Always dark.
    case darkGlass
    /// The original opaque black. Always dark.
    case solid
    /// A slab of clear tinted glass on the bottom, left and right edges. Always dark. On the top
    /// edge it resolves to `darkGlass`, so it stays welded to the bezel.
    case dock

    var id: String { rawValue }

    /// Whether this Mac has a Liquid Glass to hand the surface to. Conduit deploys to macOS 14,
    /// where `glassEffect` does not exist; the same availability the rest of the app uses
    /// (`conduitGlassSurface` in Conduit/Theme.swift).
    static var glassAvailable: Bool {
        if #available(macOS 26.0, *) { return true } else { return false }
    }

    /// The style that can actually be painted: the chosen one, except that every glass style falls
    /// back to `solid` where glass does not exist, and Reduce Transparency means "no see-through
    /// chrome", which for the notch is the solid style.
    func effective(glassAvailable: Bool = NotchSurfaceStyle.glassAvailable, reduceTransparency: Bool = false) -> NotchSurfaceStyle {
        if reduceTransparency { return .solid }
        switch self {
        case .glass, .darkGlass, .dock: return glassAvailable ? self : .solid
        case .solid: return .solid
        }
    }

    /// Whether a `glassEffect` sits under this surface at all.
    func isGlass(glassAvailable: Bool = NotchSurfaceStyle.glassAvailable) -> Bool {
        effective(glassAvailable: glassAvailable) != .solid
    }

    /// The style for a given placement. On the top edge (the default placement and a top dock) the
    /// notch has to stay welded to the bezel, so the dock style draws as the dark glass it is
    /// closest to.
    func resolved(on layout: NotchLayout) -> NotchSurfaceStyle {
        self == .dock && layout.isTopEdge ? .darkGlass : self
    }

    /// What is drawn: the placement first, then availability, then Reduce Transparency.
    func drawn(on layout: NotchLayout, glassAvailable: Bool = NotchSurfaceStyle.glassAvailable,
               reduceTransparency: Bool) -> NotchSurfaceStyle {
        resolved(on: layout).effective(glassAvailable: glassAvailable, reduceTransparency: reduceTransparency)
    }

    /// True only for the glass style actually drawn as system glass: its ink and the panel follow
    /// the Mac's light or dark appearance. Every other outcome is a dark surface.
    func followsSystemAppearance(glassAvailable: Bool = NotchSurfaceStyle.glassAvailable, reduceTransparency: Bool) -> Bool {
        effective(glassAvailable: glassAvailable, reduceTransparency: reduceTransparency) == .glass
    }

    /// The panel's own appearance. `nil` is the point of the glass style: with none of our own,
    /// light or dark and Clear or Tinted all arrive from the Mac's Appearance settings. The dark
    /// styles pin `darkAqua`, which resolves both the dynamic ink colours and SwiftUI's colour
    /// scheme. Reduce Transparency and the macOS 14 fallback draw black, where a light palette
    /// would be unreadable, so they pin it too.
    func panelAppearance(glassAvailable: Bool = NotchSurfaceStyle.glassAvailable, reduceTransparency: Bool) -> NSAppearance? {
        followsSystemAppearance(glassAvailable: glassAvailable, reduceTransparency: reduceTransparency)
            ? nil : NSAppearance(named: .darkAqua)
    }

    /// The wash laid beneath the glass (never fed to `tint`, which cannot darken adaptive glass).
    /// `nil` for the glass style keeps it the system's own glass.
    var glassDim: Color? {
        switch self {
        case .darkGlass: return NotchPalette.darkGlassDim
        case .dock: return NotchPalette.dockDim
        case .glass, .solid: return nil
        }
    }

    @available(macOS 26.0, *)
    var glass: Glass {
        switch self {
        case .darkGlass: return .clear
        case .dock: return .clear.tint(NotchPalette.dockGlassTint)
        case .glass, .solid: return .regular
        }
    }

    var title: String {
        switch self {
        case .glass: return AppLocalization.string("Liquid Glass")
        case .darkGlass: return AppLocalization.string("Dark glass")
        case .solid: return AppLocalization.string("Solid black")
        case .dock: return AppLocalization.string("Dock")
        }
    }

    var explanation: String {
        switch self {
        case .glass:
            return AppLocalization.string("System Liquid Glass. Follows this Mac's light or dark appearance and its Clear or Tinted glass setting.")
        case .darkGlass:
            return AppLocalization.string("Liquid Glass tinted black. Always dark, whatever the Mac's appearance.")
        case .solid:
            return AppLocalization.string("The original opaque black. Always dark, whatever the Mac's appearance.")
        case .dock:
            return AppLocalization.string("A slab of clear glass, like the Dock. Always dark. At the top it stays a notch.")
        }
    }
}

extension NotchLayout {
    /// The default placement and a top dock sit against the top edge (the bezel); bottom, left and
    /// right docks do not.
    var isTopEdge: Bool { dockEdge == nil || dockEdge == .maxY }
}

/// The painted surface behind the notch status view: the drawn style's fill or glass in `shape`,
/// with an optional black band across the top where the panel meets the hardware notch.
struct NotchSurfaceBackground: View {
    /// The style as drawn (`NotchSurfaceStyle.drawn`), already past the edge and availability rules.
    let style: NotchSurfaceStyle
    let shape: UnevenRoundedRectangle
    /// Height of the band that stays black where the panel touches the physical notch.
    var blackBandHeight: CGFloat = 0

    var body: some View {
        ZStack(alignment: .top) {
            surface
            if blackBandHeight > 0 {
                Rectangle().fill(NotchPalette.surface).frame(height: blackBandHeight)
            }
        }
        .clipShape(shape)
    }

    @ViewBuilder private var surface: some View {
        if style != .solid, #available(macOS 26.0, *) {
            Color.clear
                .glassEffect(style.glass, in: shape)
                .background { if let dim = style.glassDim { shape.fill(dim) } }
        } else {
            shape.fill(NotchPalette.surface)
        }
    }
}
