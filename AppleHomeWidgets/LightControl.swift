import AppIntents
import SwiftUI
import WidgetKit

/// A Control Center / Lock Screen / Action button toggle for one light.
struct LightControl: ControlWidget {
    static let kind = "Jitwisut.AppleHome.LightControl"

    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: Self.kind, provider: Provider()) { value in
            ControlWidgetToggle(isOn: value.light.isOn, action: SwitchLightIntent(lightID: value.light.id)) {
                Text(verbatim: value.light.name)
            } valueLabel: { isOn in
                Label(isOn ? "On" : "Off", systemImage: isOn ? "lightbulb.fill" : "lightbulb")
            }
            .tint(Theme.amber)
        }
        .displayName("Light")
        .description("Turn a light from your light server on or off.")
    }

    struct Value {
        var light: CachedLight
    }

    struct Provider: AppIntentControlValueProvider {
        func previewValue(configuration: SelectLightIntent) -> Value {
            Value(light: configuration.resolve(in: LightCache.lights))
        }

        func currentValue(configuration: SelectLightIntent) async throws -> Value {
            Value(light: configuration.resolve(in: await LightRemote.lights()))
        }
    }
}
