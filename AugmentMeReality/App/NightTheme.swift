import SwiftUI

/// Wave 6.2: the Night design language — 1:1 with the Figma "Night" variable
/// collection (file vgZ4zrJmznuDoQFRkI8HMY). Tokens change THERE first, then
/// here; never invent colors inline in flow screens.
enum Night {
    // MARK: Colors (Figma: Night collection)
    static let bgBase = Color(red: 0.051, green: 0.059, blue: 0.086)      // #0D0F16
    static let bgScreen = Color(red: 0.071, green: 0.082, blue: 0.122)    // #12151F
    static let glass = Color(red: 0.957, green: 0.965, blue: 0.984).opacity(0.045)
    static let lineSubtle = Color(red: 0.957, green: 0.965, blue: 0.984).opacity(0.09)
    static let ink = Color(red: 0.957, green: 0.965, blue: 0.984)         // #F4F6FB
    static let inkSecondary = ink.opacity(0.62)
    static let inkTertiary = ink.opacity(0.38)
    static let coral = Color(red: 1.0, green: 0.302, blue: 0.427)         // #FF4D6D
    static let gold = Color(red: 1.0, green: 0.784, blue: 0.341)          // #FFC857
    static let mint = Color(red: 0.239, green: 0.863, blue: 0.592)        // #3DDC97
    static let indigo = Color(red: 0.369, green: 0.361, blue: 0.902)      // #5E5CE6

    /// The signature CTA gradient (gold → coral, slight diagonal).
    static let ctaGradient = LinearGradient(
        colors: [gold, coral], startPoint: .leading, endPoint: .trailing
    )
    /// Ink used ON the CTA gradient.
    static let onCTA = Color(red: 0.10, green: 0.043, blue: 0.063)

    // MARK: Type (Figma: Display/* = Bricolage Grotesque, Mono/Label = mono)
    static func display(_ size: CGFloat) -> Font {
        .custom("Bricolage Grotesque", size: size).weight(.heavy)
    }
    static func mono(_ size: CGFloat) -> Font {
        .system(size: size, design: .monospaced).weight(.medium)
    }
}

// MARK: Reusable flow components (mirror the Figma components)

/// Gradient pill CTA — Figma "cta".
struct NightCTA: View {
    let title: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Night.onCTA)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(Night.ctaGradient, in: Capsule())
                .shadow(color: Night.coral.opacity(0.45), radius: 14, y: 6)
        }
    }
}

/// Glass pill secondary button — Figma "ghost".
struct NightGhost: View {
    let title: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14))
                .foregroundStyle(Night.inkSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Night.glass, in: Capsule())
                .overlay(Capsule().strokeBorder(Night.lineSubtle))
        }
    }
}

/// Glass card container — Figma "card".
struct NightCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Night.glass, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Night.lineSubtle))
    }
}

/// Mono label chip — Figma "tag" / "maplabel" / "distchip".
struct NightChip: View {
    let text: String
    var tint: Color = Night.inkTertiary
    var body: some View {
        Text(text)
            .font(Night.mono(11))
            .kerning(0.9)
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Night.bgBase.opacity(0.78), in: Capsule())
            .overlay(Capsule().strokeBorder(Night.lineSubtle))
    }
}

/// Gradient monogram avatar — Figma "avatar".
struct NightAvatar: View {
    let monogram: String
    var size: CGFloat = 44
    var warm = false
    var body: some View {
        ZStack {
            Circle().fill(
                LinearGradient(
                    colors: warm ? [Night.coral, Night.gold] : [Night.indigo, Color(red: 0.2, green: 0.68, blue: 0.9)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            )
            Text(monogram)
                .font(.system(size: size * 0.34, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}
