import AppIntents
import SwiftUI
import WidgetKit

/// Home Screen and Lock Screen widget: one light, with a button that switches it.
struct LightWidget: Widget {
    static let kind = "Jitwisut.AppleHome.LightWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Self.kind, intent: SelectLightIntent.self, provider: Provider()) { entry in
            LightWidgetView(entry: entry)
        }
        .configurationDisplayName("Light")
        .description("See and switch a light from your light server.")
        .supportedFamilies([.systemSmall, .accessoryCircular])
    }

    struct Entry: TimelineEntry {
        var date = Date.now
        var light: CachedLight
        var isSetUp: Bool
    }

    struct Provider: AppIntentTimelineProvider {
        func placeholder(in context: Context) -> Entry {
            Entry(light: .fallback, isSetUp: true)
        }

        func snapshot(for configuration: SelectLightIntent, in context: Context) async -> Entry {
            let lights = context.isPreview ? LightCache.lights : await LightRemote.lights()
            return entry(configuration, lights)
        }

        func timeline(for configuration: SelectLightIntent, in context: Context) async -> Timeline<Entry> {
            // The app and the widget's own button reload this right after a switch, so the
            // schedule only has to catch changes made elsewhere (a wall switch, another phone).
            Timeline(entries: [entry(configuration, await LightRemote.lights())],
                     policy: .after(.now.addingTimeInterval(15 * 60)))
        }

        private func entry(_ configuration: SelectLightIntent, _ lights: [CachedLight]) -> Entry {
            Entry(light: configuration.resolve(in: lights), isSetUp: LightRemote.isSetUp)
        }
    }
}

private struct LightWidgetView: View {
    let entry: LightWidget.Entry
    @Environment(\.widgetFamily) private var family

    private var isOn: Bool { entry.light.isOn }
    private var symbol: String { isOn ? "lightbulb.fill" : "lightbulb" }
    private var toggle: SwitchLightIntent { SwitchLightIntent(lightID: entry.light.id, value: !isOn) }

    var body: some View {
        switch family {
        case .accessoryCircular: circular
        default: small
        }
    }

    private var circular: some View {
        Button(intent: toggle) {
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: symbol)
                    .font(.title2.weight(.semibold))
                    .widgetAccentable()
            }
        }
        .buttonStyle(.plain)
        .disabled(!entry.isSetUp)
        .containerBackground(.clear, for: .widget)
        .accessibilityLabel(Text(verbatim: entry.light.name))
        .accessibilityValue(isOn ? Text("On") : Text("Off"))
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Image(systemName: symbol)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(isOn ? AnyShapeStyle(Theme.warmGradient) : AnyShapeStyle(Theme.textTertiary))
                    .shadow(color: isOn ? Theme.amber.opacity(0.7) : .clear, radius: 10)
                Spacer()
                if entry.isSetUp {
                    Button(intent: toggle) {
                        Image(systemName: "power")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(isOn ? Theme.night1 : .white)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(isOn ? AnyShapeStyle(Theme.warmGradient) : AnyShapeStyle(Color.white.opacity(0.14))))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isOn ? Text("Turn Off") : Text("Turn On"))
                }
            }
            Spacer(minLength: 8)
            if entry.isSetUp {
                Text(verbatim: entry.light.name)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(isOn ? "On" : "Off")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(isOn ? Theme.amber : Theme.textSecondary)
            } else {
                Text("Set up a light server in AppleHome first.")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(3)
            }
        }
        .containerBackground(for: .widget) {
            ZStack {
                LinearGradient(colors: [Theme.night0, Theme.night2], startPoint: .top, endPoint: .bottom)
                if isOn {
                    RadialGradient(colors: [Theme.amber.opacity(0.35), .clear], center: .topLeading,
                                   startRadius: 0, endRadius: 140)
                }
            }
        }
    }
}
