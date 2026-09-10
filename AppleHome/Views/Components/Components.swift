import SwiftUI

// MARK: Background

/// Deep night sky with a few stars and a warm glow that brightens with the lights.
struct NightBackground: View {
    var glow: Double = 0
    var accent: Color = Theme.amber

    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.night0, Theme.night1, Theme.night2], startPoint: .top, endPoint: .bottom)
            StarField().opacity(0.6)
            RadialGradient(
                colors: [accent.opacity(0.08 + 0.32 * glow), accent.opacity(0.02), .clear],
                center: UnitPoint(x: 0.5, y: 0.3), startRadius: 8, endRadius: 380
            )
            .animation(.softSpring, value: glow)
        }
        .ignoresSafeArea()
    }
}

private struct StarField: View {
    var body: some View {
        Canvas { context, size in
            var rng = SeededGenerator(seed: 11)
            for _ in 0..<80 {
                let x = Double.random(in: 0...1, using: &rng) * size.width
                let y = pow(Double.random(in: 0...1, using: &rng), 1.8) * size.height * 0.55
                let r = Double.random(in: 0.5...1.6, using: &rng)
                context.opacity = Double.random(in: 0.15...0.8, using: &rng)
                context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r, height: r)), with: .color(.white))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

// MARK: Glass

extension View {
    /// Liquid Glass panel with a soft top highlight for depth.
    func glassCard(cornerRadius: CGFloat = Theme.cardRadius, tint: Color? = nil, interactive: Bool = false) -> some View {
        self
            .glassEffect(interactive ? .regular.tint(tint).interactive() : .regular.tint(tint), in: .rect(cornerRadius: cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.03)], startPoint: .top, endPoint: .bottom),
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
            }
    }
}

/// Press feedback: card sinks and tilts back slightly, like pressing a physical tile.
struct PressableCardStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.965 : 1)
            .rotation3DEffect(
                .degrees(configuration.isPressed && !reduceMotion ? 8 : 0),
                axis: (x: 1, y: 0, z: 0), anchor: .center, perspective: 0.45
            )
            .animation(.snappySpring, value: configuration.isPressed)
    }
}

// MARK: Light pieces

struct LightGlyph: View {
    let kind: LightKind
    let isOn: Bool
    var size: CGFloat = 46

    var body: some View {
        ZStack {
            Circle()
                .fill(isOn
                      ? AnyShapeStyle(RadialGradient(colors: [.white, Theme.amber, Theme.amberDeep],
                                                     center: UnitPoint(x: 0.35, y: 0.3), startRadius: 1, endRadius: size * 0.8))
                      : AnyShapeStyle(Color.white.opacity(0.08)))
            Image(systemName: kind.symbol)
                .symbolVariant(isOn ? .fill : .none)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(isOn ? Color.black.opacity(0.72) : Color.white.opacity(0.82))
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: isOn)
        }
        .frame(width: size, height: size)
        .shadow(color: isOn ? Theme.amber.opacity(0.75) : .clear, radius: isOn ? 14 : 0)
        .accessibilityHidden(true)
    }
}

struct PowerButton: View {
    let isOn: Bool
    var size: CGFloat = 44
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "power")
                .font(.system(size: size * 0.38, weight: .bold))
                .foregroundStyle(isOn ? Color.black.opacity(0.78) : .white)
                .frame(width: size, height: size)
                .background {
                    Circle().fill(isOn ? AnyShapeStyle(Theme.warmGradient) : AnyShapeStyle(Color.white.opacity(0.1)))
                }
                .overlay(Circle().strokeBorder(.white.opacity(isOn ? 0.4 : 0.16), lineWidth: 1))
                .shadow(color: isOn ? Theme.amber.opacity(0.7) : .clear, radius: 10)
                .contentShape(Circle())
        }
        .buttonStyle(PressableCardStyle())
        .sensoryFeedback(.impact(weight: .medium), trigger: isOn)
        .accessibilityLabel(isOn ? Text("Turn off") : Text("Turn on"))
    }
}

struct BrightnessBar: View {
    var value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.1))
                Capsule()
                    .fill(Theme.warmGradient)
                    .frame(width: max(0, geo.size.width * value))
                    .shadow(color: Theme.amber.opacity(0.6), radius: 6)
            }
        }
        .frame(height: 5)
        .accessibilityHidden(true)
    }
}

// MARK: Small building blocks

struct SectionTitle: View {
    let title: Text
    var trailing: Text?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            title.font(.title3.weight(.semibold)).foregroundStyle(.white)
            Spacer()
            trailing?.font(.subheadline).foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 4)
    }
}

struct IconBadge: View {
    let symbol: String
    var color: Color = Theme.amber
    var size: CGFloat = 40

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.16), in: .rect(cornerRadius: size * 0.32))
            .accessibilityHidden(true)
    }
}

enum Format {
    static func distance(_ meters: Double) -> String {
        if meters >= 1000 {
            return Measurement(value: meters / 1000, unit: UnitLength.kilometers)
                .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0...1))))
        }
        let rounded = (meters / 10).rounded() * 10
        return Measurement(value: rounded, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0))))
    }
}
