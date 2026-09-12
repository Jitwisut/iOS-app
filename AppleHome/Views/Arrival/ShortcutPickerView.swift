import SwiftUI

struct ShortcutPickerView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let saved = model.settings.shortcuts
        let selection = model.arrival.settings.arrivalShortcutIDs
        List {
            if saved.isEmpty {
                Section {
                    VStack(spacing: 10) {
                        Image(systemName: "bolt.slash")
                            .font(.system(size: 30))
                            .foregroundStyle(Theme.textSecondary)
                        Text("No saved shortcuts yet")
                            .font(.headline)
                            .foregroundStyle(.white)
                        Text("Add one in Settings › Shortcuts first.")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                            .multilineTextAlignment(.center)
                        Button("Open Settings") { model.selectedTab = .settings }
                            .buttonStyle(.glassProminent)
                            .tint(Theme.amber)
                            .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                    .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(saved) { item in
                        Button {
                            toggle(item.id)
                        } label: {
                            row(title: Text(item.name), checked: selection.contains(item.id))
                        }
                    }
                } footer: {
                    Text("Runs alongside your lights when you arrive. Works best while AppleHome is open — in the background, iOS may not let it switch to Shortcuts.")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(NightBackground(glow: 0.2, accent: Theme.mint))
        .navigationTitle(Text("Shortcuts"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }

    private func toggle(_ id: UUID) {
        var ids = model.arrival.settings.arrivalShortcutIDs
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        model.arrival.settings.arrivalShortcutIDs = ids
    }

    private func row(title: Text, checked: Bool) -> some View {
        HStack(spacing: 14) {
            IconBadge(symbol: "bolt.fill", color: checked ? Theme.amber : Theme.textSecondary, size: 34)
            title.foregroundStyle(.white)
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
