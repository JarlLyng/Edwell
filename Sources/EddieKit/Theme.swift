import IAMJARLDesignTokens
import SwiftUI

/// Every colour, size and radius in Eddie's interface comes from the IAMJARL design system.
/// Colours in the video itself (title colours, the project background) are the user's content, not UI.
typealias Tokens = DesignTokens

extension Tokens {
    /// A clip's fill by its kind: the design system's categorical fills (iamjarl-design#112), which
    /// `text.primary` reads on in both modes and which keep clear of `primary` and the state colours.
    /// A selected clip keeps its fill; the selection is the `primary` border.
    static func clipFill(_ kind: ClipKind) -> Color {
        switch kind {
        case .video: Palette.Category.blue
        case .image: Palette.Category.amber
        case .audio: Palette.Category.teal
        case .title: Palette.Category.rose
        }
    }

    /// The same fill for a file in the media bin, by the kind of clip it becomes.
    static func clipFill(_ kind: MediaKind) -> Color {
        switch kind {
        case .video: clipFill(ClipKind.video)
        case .image: clipFill(ClipKind.image)
        case .audio: clipFill(ClipKind.audio)
        }
    }
}

/// The design system's primary button: `primary` with `onPrimary` text. Compact, it fits the toolbar.
struct PrimaryButtonStyle: ButtonStyle {
    var compact = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .ijFont(compact ? .sm : .base, weight: .semibold)
            .foregroundStyle(Tokens.Palette.onPrimary)
            .padding(.vertical, compact ? Self.toolbarPadding : Tokens.Spacing.sm)
            .padding(.horizontal, compact ? Tokens.Spacing.md : Tokens.Spacing.xl)
            .background(configuration.isPressed ? Tokens.Palette.primaryPressed : Tokens.Palette.primary,
                        in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
            .opacity(isEnabled ? 1 : Tokens.Opacity.disabled)
    }

    /// As tall as the toolbar's glass from macOS 26, and as its controls before.
    private static var toolbarPadding: CGFloat {
        if #available(macOS 26, *) { Tokens.Spacing.sm } else { Tokens.Spacing.xs }
    }
}

/// The design system's secondary button: a card with a subtle border.
struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .ijFont(.base)
            .foregroundStyle(Tokens.Palette.Text.primary)
            .padding(.vertical, Tokens.Spacing.sm)
            .padding(.horizontal, Tokens.Spacing.xl)
            .background(configuration.isPressed ? Tokens.Palette.Background.muted : Tokens.Palette.Background.card,
                        in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
            .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.md).strokeBorder(Tokens.Palette.Border.subtle))
            .opacity(isEnabled ? 1 : Tokens.Opacity.disabled)
    }
}
