import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.selectedTab) {
            Tab("Home", systemImage: "house.fill", value: AppTab.home) {
                HomeView()
            }
            Tab("Arrival", systemImage: "location.circle.fill", value: AppTab.arrival) {
                ArrivalView()
            }
            Tab("Settings", systemImage: "gearshape.fill", value: AppTab.settings) {
                SettingsView()
            }
        }
        .tint(Theme.amber)
        .preferredColorScheme(.dark)
        .overlay(alignment: .top) { ErrorBanner() }
        .onOpenURL { url in
            model.handleShortcutCallback(url)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.location.startLiveUpdates()
                Task { await model.store.refresh() }
            } else if phase == .background {
                model.location.stopLiveUpdates()
            }
        }
        #if DEBUG
        .onAppear {
            // Screenshot helper: `-tab arrival` / `-tab settings` launch argument.
            switch UserDefaults.standard.string(forKey: "tab") {
            case "arrival": model.selectedTab = .arrival
            case "settings": model.selectedTab = .settings
            default: break
            }
        }
        #endif
    }
}

private struct ErrorBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let message = model.store.errorMessage
        ZStack {
            if let message {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.danger)
                    Text(message)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                        .lineLimit(3)
                    Spacer(minLength: 0)
                    Button {
                        model.store.errorMessage = nil
                    } label: {
                        Image(systemName: "xmark").frame(width: 32, height: 32)
                    }
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityLabel(Text("Dismiss"))
                }
                .padding(.leading, 16)
                .padding(.trailing, 8)
                .padding(.vertical, 8)
                .glassEffect(.regular.tint(Theme.danger.opacity(0.18)), in: .rect(cornerRadius: 22))
                .padding(.horizontal, 16)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: message) {
                    try? await Task.sleep(for: .seconds(5))
                    withAnimation(.snappySpring) { model.store.errorMessage = nil }
                }
            }
        }
        .animation(.snappySpring, value: message)
    }
}
