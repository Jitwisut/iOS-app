import SwiftUI

/// Choose which lights the arrival automation controls. An empty selection means "all".
struct LightPickerView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.store
        let selection = model.arrival.settings.lightIDs
        List {
            Section {
                Button {
                    model.arrival.settings.lightIDs = []
                } label: {
                    row(title: Text("All lights"), subtitle: Text("Including lights you add later"),
                        symbol: "lightbulb.2.fill", checked: selection.isEmpty)
                }
            }
            ForEach(store.rooms, id: \.self) { room in
                Section(room) {
                    ForEach(store.lights.filter { $0.room == room }) { light in
                        Button {
                            toggle(light.id)
                        } label: {
                            row(title: Text(light.name), subtitle: Text(light.source.displayName),
                                symbol: light.kind.symbol, checked: selection.contains(light.id))
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(NightBackground(glow: 0.2, accent: Theme.cyan))
        .navigationTitle(Text("Lights"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }

    private func toggle(_ id: String) {
        var ids = model.arrival.settings.lightIDs
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        model.arrival.settings.lightIDs = ids
    }

    private func row(title: Text, subtitle: Text, symbol: String, checked: Bool) -> some View {
        HStack(spacing: 14) {
            IconBadge(symbol: symbol, color: checked ? Theme.amber : Theme.textSecondary, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                title.foregroundStyle(.white)
                subtitle.font(.caption).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(checked ? Theme.amber : Theme.textTertiary)
                .contentTransition(.symbolEffect(.replace))
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .sensoryFeedback(.selection, trigger: checked)
        .accessibilityAddTraits(checked ? .isSelected : [])
    }
}
