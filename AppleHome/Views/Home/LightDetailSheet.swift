import SwiftUI

struct LightDetailSheet: View {
    let lightID: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            NightBackground(glow: (light?.isOn ?? false) ? (light?.brightness ?? 0) : 0)
            if let light {
                content(light)
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(36)
    }

    private var light: Light? { model.store.light(lightID) }

    private func content(_ light: Light) -> some View {
        let store = model.store
        return VStack(spacing: 0) {
            HStack(alignment: .top) {
                LightGlyph(kind: light.kind, isOn: light.isOn, size: 52)
                VStack(alignment: .leading, spacing: 4) {
                    Text(light.name)
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                    HStack(spacing: 6) {
                        Text(light.room)
                        Text("·")
                        Label(light.source.displayName, systemImage: light.source.symbol)
                    }
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                }
                .padding(.leading, 6)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel(Text("Close"))
            }
            .padding(.top, 28)

            Spacer(minLength: 20)

            Text(light.isOn
                 ? (light.supportsBrightness ? "\(light.percent)%" : String(localized: "On"))
                 : String(localized: "Off"))
                .font(.numeric(52, weight: .bold))
                .foregroundStyle(light.isOn ? Theme.amber : Theme.textSecondary)
                .contentTransition(.numericText(value: Double(light.percent)))
                .animation(.snappySpring, value: light.percent)
                .shadow(color: Theme.amber.opacity(light.isOn ? 0.5 : 0), radius: 16)

            if light.supportsBrightness {
                BrightnessPill(value: light.brightness, isOn: light.isOn) { value in
                    store.setBrightness(value, id: light.id)
                }
                .frame(width: 136, height: 330)
                .padding(.top, 18)

                HStack(spacing: 10) {
                    ForEach([0.25, 0.5, 0.75, 1.0], id: \.self) { preset in
                        let selected = light.isOn && abs(light.brightness - preset) < 0.02
                        Button {
                            withAnimation(.snappySpring) { store.setBrightness(preset, id: light.id) }
                        } label: {
                            Text("\(Int(preset * 100))%")
                                .font(.numeric(15))
                                .frame(minWidth: 56, minHeight: 44)
                        }
                        .buttonStyle(.glass)
                        .tint(selected ? Theme.amber : nil)
                    }
                }
                .padding(.top, 22)
            }

            Spacer(minLength: 20)

            PowerButton(isOn: light.isOn, size: 72) { store.toggle(light) }
                .padding(.bottom, 24)
        }
        .padding(.horizontal, 24)
    }
}

/// Tall frosted pill: drag up/down to set brightness, like the Control Center slider.
struct BrightnessPill: View {
    var value: Double
    var isOn: Bool
    var onChange: (Double) -> Void

    @State private var dragStart: Double?
    private let radius: CGFloat = 42

    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height
            let level = isOn ? value : 0
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: radius).fill(.white.opacity(0.07))
                LinearGradient(colors: [Theme.amberDeep, Theme.amber, Color(red: 1, green: 0.93, blue: 0.8)],
                               startPoint: .bottom, endPoint: .top)
                    .frame(height: height * level)
                    .overlay(alignment: .top) {
                        Capsule().fill(.white.opacity(0.85)).frame(width: 44, height: 5).padding(.top, 10)
                            .opacity(level > 0.08 ? 1 : 0)
                    }
                Image(systemName: level > 0.5 ? "sun.max.fill" : "sun.min.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(level > 0.12 ? Color.black.opacity(0.55) : Theme.textSecondary)
                    .padding(.bottom, 22)
                    .contentTransition(.symbolEffect(.replace))
            }
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .overlay {
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.3), .white.opacity(0.05)],
                                                 startPoint: .top, endPoint: .bottom), lineWidth: 1)
            }
            .glassEffect(.regular, in: .rect(cornerRadius: radius))
            .shadow(color: Theme.amber.opacity(0.45 * level), radius: 34)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let start = dragStart ?? level
                        if dragStart == nil { dragStart = start }
                        onChange(min(max(start - drag.translation.height / height, 0), 1))
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .animation(dragStart == nil ? .snappySpring : nil, value: level)
        }
        .sensoryFeedback(.selection, trigger: Int((isOn ? value : 0) * 20))
        .accessibilityElement()
        .accessibilityLabel(Text("Brightness"))
        .accessibilityValue(Text("\(Int((isOn ? value : 0) * 100))%"))
        .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? 0.1 : -0.1
            onChange(min(max((isOn ? value : 0) + step, 0), 1))
        }
    }
}
