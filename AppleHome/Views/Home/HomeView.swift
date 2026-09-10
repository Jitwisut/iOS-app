import SwiftUI

private struct LightRef: Identifiable { let id: String }

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var openLight: LightRef?

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        let store = model.store
        ZStack {
            NightBackground(glow: store.ambientGlow)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    hero
                    if !store.rooms.isEmpty { roomChips }
                    lights
                    arrivalCard
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 28)
            }
            .scrollIndicators(.hidden)
            .refreshable { await store.refresh() }
        }
        .sheet(item: $openLight) { ref in
            LightDetailSheet(lightID: ref.id)
        }
        #if DEBUG
        .task(id: model.store.lights.isEmpty) {
            // Screenshot helper: `-openLight <light id>` launch argument.
            if let id = UserDefaults.standard.string(forKey: "openLight"), model.store.light(id) != nil {
                openLight = LightRef(id: id)
            }
        }
        #endif
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(greeting)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                LocationPill()
            }
            Text(model.homeName)
                .font(.largeTitle.bold())
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.top, 8)
    }

    private var greeting: LocalizedStringKey {
        switch Calendar.current.component(.hour, from: .now) {
        case 5..<12: "Good morning"
        case 12..<17: "Good afternoon"
        case 17..<22: "Good evening"
        default: "Good night"
        }
    }

    // MARK: 3D hero

    private var hero: some View {
        let store = model.store
        return ZStack(alignment: .bottom) {
            Ellipse()
                .fill(RadialGradient(colors: [Theme.amber.opacity(0.08 + 0.4 * store.ambientGlow), .clear],
                                     center: .center, startRadius: 4, endRadius: 170))
                .frame(height: 150)
                .blur(radius: 24)
                .offset(y: -70)
                .animation(.softSpring, value: store.ambientGlow)

            House3DView(rooms: store.roomGlows, selectedRoom: store.selectedRoom) { room in
                withAnimation(.snappySpring) { store.selectedRoom = room }
            }
            .frame(height: 330)
            .overlay(alignment: .topLeading) {
                Label("Drag to rotate · Tap a room", systemImage: "hand.draw")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 4)
            }

            summaryBar
        }
    }

    private var summaryBar: some View {
        let store = model.store
        let scope = store.selectedRoom
        let scoped = scope.map { room in store.lights.filter { $0.room == room } } ?? store.lights
        let on = scoped.count(where: \.isOn)
        return HStack(spacing: 12) {
            Image(systemName: on > 0 ? "lightbulb.max.fill" : "lightbulb")
                .font(.title3)
                .foregroundStyle(on > 0 ? Theme.amber : Theme.textSecondary)
                .symbolEffect(.bounce, value: on)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(on) of \(scoped.count) on")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                Text(scope ?? String(localized: "Whole home"))
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Button {
                store.setAll(on == 0, room: scope)
            } label: {
                Text(on > 0 ? "All off" : "All on")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.glass)
            .disabled(scoped.isEmpty)
            .sensoryFeedback(.impact(weight: .heavy), trigger: on == 0)
        }
        .padding(.leading, 18)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .glassCard(cornerRadius: 30)
        .animation(.snappySpring, value: on)
    }

    // MARK: Rooms

    private var roomChips: some View {
        let store = model.store
        return ScrollView(.horizontal) {
            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 10) {
                    RoomChip(title: String(localized: "All"), onCount: store.onCount, isSelected: store.selectedRoom == nil) {
                        store.selectedRoom = nil
                    }
                    ForEach(store.rooms, id: \.self) { room in
                        RoomChip(title: room, onCount: store.onCount(in: room), isSelected: store.selectedRoom == room) {
                            store.selectedRoom = store.selectedRoom == room ? nil : room
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        .animation(.snappySpring, value: store.selectedRoom)
    }

    // MARK: Lights

    @ViewBuilder
    private var lights: some View {
        let store = model.store
        SectionTitle(
            title: Text(store.selectedRoom ?? String(localized: "All lights")),
            trailing: Text("\(store.visibleLights.count(where: \.isOn)) on")
        )
        if store.lights.isEmpty {
            if store.isLoading {
                ProgressView().tint(.white).frame(maxWidth: .infinity, minHeight: 160)
            } else {
                EmptyLightsCard { model.selectedTab = .settings }
            }
        } else {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(store.visibleLights) { light in
                    LightCard(light: light) {
                        store.toggle(light)
                    } onOpen: {
                        openLight = LightRef(id: light.id)
                    }
                }
            }
        }
    }

    // MARK: Arrival

    private var arrivalCard: some View {
        let settings = model.arrival.settings
        return Button {
            model.selectedTab = .arrival
        } label: {
            HStack(spacing: 14) {
                IconBadge(symbol: "location.circle.fill", color: Theme.cyan, size: 46)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Arrival lights")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(settings.isEnabled
                         ? String(localized: "On · \(Format.distance(settings.radius)) around home")
                         : String(localized: "Turn lights on automatically when you get home"))
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(16)
            .glassCard(tint: settings.isEnabled ? Theme.cyan.opacity(0.1) : nil)
            .contentShape(.rect(cornerRadius: Theme.cardRadius))
        }
        .buttonStyle(PressableCardStyle())
    }
}

private struct RoomChip: View {
    let title: String
    let onCount: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isSelected ? .white : Theme.textSecondary)
                if onCount > 0 {
                    Text("\(onCount)")
                        .font(.numeric(12, weight: .bold))
                        .foregroundStyle(.black.opacity(0.75))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Theme.amber, in: .capsule)
                }
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .glassEffect(.regular.tint(isSelected ? Theme.amber.opacity(0.32) : nil).interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct LocationPill: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let arrival = model.arrival
        Button {
            model.selectedTab = .arrival
        } label: {
            HStack(spacing: 6) {
                Image(systemName: arrival.isHome == true ? "house.fill" : "location.fill")
                    .foregroundStyle(arrival.isHome == true ? Theme.mint : Theme.cyan)
                Text(label)
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
            }
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            .glassEffect(.regular.interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
    }

    private var label: String {
        let arrival = model.arrival
        if arrival.settings.home == nil { return String(localized: "Set home") }
        if arrival.isHome == true { return String(localized: "At home") }
        if let d = arrival.distanceToHome { return String(localized: "\(Format.distance(d)) away") }
        return String(localized: "Away")
    }
}

private struct EmptyLightsCard: View {
    let action: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "lightbulb.slash")
                .font(.system(size: 34))
                .foregroundStyle(Theme.textSecondary)
            Text("No lights yet")
                .font(.headline)
                .foregroundStyle(.white)
            Text("Connect your light server or Apple Home, or turn on demo lights.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Button("Open Settings", action: action)
                .buttonStyle(.glassProminent)
                .tint(Theme.amber)
                .padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .glassCard()
    }
}
