import SwiftUI

struct LightCard: View {
    let light: Light
    let onToggle: () -> Void
    let onOpen: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onOpen) { card }
                .buttonStyle(PressableCardStyle())
            PowerButton(isOn: light.isOn, action: onToggle)
                .padding(12)
                .disabled(!light.isReachable)
        }
        .opacity(light.isReachable ? 1 : 0.55)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            LightGlyph(kind: light.kind, isOn: light.isOn)
            Spacer(minLength: 14)
            Text(light.name)
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Text(status)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(light.isOn ? Theme.amber : Theme.textSecondary)
                .contentTransition(.numericText())
                .padding(.top, 4)
            BrightnessBar(value: light.isOn ? light.brightness : 0)
                .padding(.top, 14)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 184, alignment: .topLeading)
        .background {
            // Light "spilling" from the lamp corner.
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .fill(RadialGradient(
                    colors: [Theme.amber.opacity(0.5), Theme.amberDeep.opacity(0.14), .clear],
                    center: .topLeading, startRadius: 6, endRadius: 230
                ))
                .opacity(light.isOn ? 0.45 + 0.55 * light.brightness : 0)
        }
        .glassCard(tint: light.isOn ? Theme.amber.opacity(0.12) : nil)
        .shadow(color: light.isOn ? Theme.amber.opacity(0.22 + 0.2 * light.brightness) : .black.opacity(0.35),
                radius: light.isOn ? 22 : 12, y: light.isOn ? 6 : 10)
        .contentShape(.rect(cornerRadius: Theme.cardRadius))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(light.name))
        .accessibilityValue(Text(status))
        .accessibilityHint(Text("Opens brightness controls"))
    }

    private var status: String {
        if !light.isReachable { return String(localized: "No response") }
        guard light.isOn else { return String(localized: "Off") }
        return light.supportsBrightness ? "\(light.percent)%" : String(localized: "On")
    }
}
