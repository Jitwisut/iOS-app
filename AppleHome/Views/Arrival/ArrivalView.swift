import SwiftUI
import MapKit

struct ArrivalView: View {
    @Environment(AppModel.self) private var model
    @State private var camera: MapCameraPosition = .automatic
    @State private var radiusDraft: Double?
    @State private var runningTest = false

    private var radius: Double { radiusDraft ?? model.arrival.settings.radius }

    var body: some View {
        NavigationStack {
            ZStack {
                NightBackground(glow: 0.35, accent: Theme.cyan)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        titleBlock
                        if !model.location.canMonitorInBackground { PermissionCard() }
                        mapCard
                        radiusCard
                        automationCard
                        if model.settings.homeKitEnabled { HomeKitAutomationCard() }
                        testCard
                        recentActivity
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 28)
                }
                .scrollIndicators(.hidden)
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: String.self) { _ in LightPickerView() }
        }
        .onAppear {
            // Open on the home zone (not the user, who may be kilometres away).
            if let home = model.arrival.settings.home {
                camera = homeCamera(home)
            } else {
                camera = .userLocation(fallback: .automatic)
            }
        }
    }

    // MARK: Title

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Arrive Home")
                .font(.largeTitle.bold())
                .foregroundStyle(.white)
            Text("Your lights turn on by themselves as you get close to home.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.top, 8)
    }

    // MARK: Map

    private var mapCard: some View {
        let arrival = model.arrival
        return MapReader { proxy in
            Map(position: $camera, interactionModes: [.pan, .zoom, .rotate, .pitch]) {
                if let home = arrival.settings.home {
                    MapCircle(center: home.clCoordinate, radius: radius)
                        .foregroundStyle(Theme.cyan.opacity(0.16))
                        .stroke(Theme.cyan.opacity(0.95), lineWidth: 2)
                    Annotation("Home", coordinate: home.clCoordinate, anchor: .center) {
                        HomePin(isHome: arrival.isHome == true)
                    }
                }
                UserAnnotation()
            }
            .mapStyle(.standard(elevation: .realistic, emphasis: .muted, pointsOfInterest: .excludingAll))
            .mapControls { MapCompass() }
            .onTapGesture { point in
                guard let coordinate = proxy.convert(point, from: .local) else { return }
                withAnimation(.snappySpring) { model.arrival.settings.home = Coordinate(coordinate) }
            }
        }
        .frame(height: 340)
        .clipShape(.rect(cornerRadius: Theme.cardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.hairline, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.45), radius: 20, y: 12)
        .overlay(alignment: .top) { statusPill.padding(12) }
        .overlay(alignment: .bottomTrailing) {
            Button {
                useCurrentLocation()
            } label: {
                Label("Use my location", systemImage: "location.fill")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.glass)
            .tint(Theme.cyan)
            .disabled(model.location.location == nil)
            .padding(12)
        }
    }

    private var statusPill: some View {
        let arrival = model.arrival
        let (symbol, color, text): (String, Color, String) = {
            guard arrival.settings.home != nil else {
                return ("hand.tap.fill", Theme.cyan, String(localized: "Tap the map to set your home"))
            }
            if arrival.isHome == true { return ("house.fill", Theme.mint, String(localized: "You're home")) }
            if let d = arrival.distanceToHome { return ("location.fill", Theme.cyan, String(localized: "\(Format.distance(d)) from home")) }
            return ("location.slash", Theme.textSecondary, String(localized: "Waiting for your location"))
        }()
        return HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).foregroundStyle(.white).contentTransition(.numericText())
        }
        .font(.footnote.weight(.semibold))
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .glassEffect(.regular, in: .capsule)
        .animation(.snappySpring, value: text)
    }

    // MARK: Radius

    private var radiusCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Arrival zone").font(.headline).foregroundStyle(.white)
                    Text("Radius around home").font(.subheadline).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Text(Format.distance(radius))
                    .font(.numeric(34, weight: .bold))
                    .foregroundStyle(Theme.cyan)
                    .contentTransition(.numericText(value: radius))
                    .animation(.snappySpring, value: radius)
            }

            Slider(
                value: Binding(get: { radius }, set: { radiusDraft = $0 }),
                in: ArrivalSettings.radiusRange, step: 50
            ) {
                Text("Radius")
            } onEditingChanged: { editing in
                if !editing, let draft = radiusDraft {
                    model.arrival.settings.radius = draft
                    radiusDraft = nil
                    focusHome()
                }
            }
            .tint(Theme.cyan)
            .sensoryFeedback(.selection, trigger: radius)

            HStack(spacing: 8) {
                ForEach([150.0, 300, 500, 1000], id: \.self) { preset in
                    Button {
                        withAnimation(.snappySpring) { model.arrival.settings.radius = preset }
                        focusHome()
                    } label: {
                        Text(Format.distance(preset))
                            .font(.numeric(14))
                            .frame(maxWidth: .infinity, minHeight: 40)
                    }
                    .buttonStyle(.glass)
                    .tint(abs(radius - preset) < 1 ? Theme.cyan : nil)
                }
            }

            Text("200 m or more works most reliably. A bigger zone turns lights on earlier.")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(18)
        .glassCard()
    }

    // MARK: Automation options

    private var automationCard: some View {
        @Bindable var arrival = model.arrival
        return VStack(spacing: 0) {
            Toggle(isOn: Binding(
                get: { arrival.settings.isEnabled },
                set: { enable($0) }
            )) {
                HStack(spacing: 14) {
                    IconBadge(symbol: "lightbulb.max.fill", color: Theme.amber, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Turn on lights when I arrive")
                            .font(.headline)
                            .foregroundStyle(.white)
                        Text(arrival.settings.isEnabled ? "Active" : "Off")
                            .font(.subheadline)
                            .foregroundStyle(arrival.settings.isEnabled ? Theme.mint : Theme.textSecondary)
                    }
                }
            }
            .tint(Theme.amber)
            .padding(16)
            .sensoryFeedback(.success, trigger: arrival.settings.isEnabled)

            Divider().overlay(Theme.hairline)

            NavigationLink(value: "lights") {
                OptionRow(symbol: "lightbulb.2.fill", title: Text("Lights")) {
                    Text(arrival.settings.lightIDs.isEmpty
                         ? String(localized: "All lights")
                         : String(localized: "\(arrival.settings.lightIDs.count) lights"))
                        .foregroundStyle(Theme.textSecondary)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .buttonStyle(.plain)

            Divider().overlay(Theme.hairline)

            VStack(alignment: .leading, spacing: 10) {
                OptionRow(symbol: "figure.walk.departure", title: Text("When I leave")) { EmptyView() }
                Picker("When I leave", selection: $arrival.settings.onLeave) {
                    Text("Turn lights off").tag(LeaveAction.turnOff)
                    Text("Do nothing").tag(LeaveAction.nothing)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
            }

            Divider().overlay(Theme.hairline)

            Toggle(isOn: $arrival.settings.onlyAfterDark) {
                OptionLabel(symbol: "moon.stars.fill", title: Text("Only after sunset"),
                            subtitle: Text("Skip it during daylight"))
            }
            .tint(Theme.amber)
            .padding(16)

            Divider().overlay(Theme.hairline)

            Toggle(isOn: Binding(
                get: { arrival.settings.notify },
                set: { on in
                    arrival.settings.notify = on
                    if on { Task { await arrival.requestNotificationPermission() } }
                }
            )) {
                OptionLabel(symbol: "bell.badge.fill", title: Text("Notify me"),
                            subtitle: Text("A short message when lights change"))
            }
            .tint(Theme.amber)
            .padding(16)
        }
        .glassCard()
    }

    // MARK: Test

    private var testCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Try it now").font(.headline).foregroundStyle(.white)
            Text("Runs the same actions right away, so you can check which lights respond.")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
            HStack(spacing: 10) {
                Button {
                    runTest(.entered)
                } label: {
                    Label("Simulate arrival", systemImage: "house.fill")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.amber.opacity(0.85))

                Button {
                    runTest(.exited)
                } label: {
                    Label("Leaving", systemImage: "figure.walk.departure")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.glass)
            }
            .font(.subheadline.weight(.semibold))
            .disabled(runningTest)
        }
        .padding(18)
        .glassCard()
    }

    @ViewBuilder
    private var recentActivity: some View {
        let entries = Array(model.log.entries.prefix(4))
        if !entries.isEmpty {
            SectionTitle(title: Text("Recent"))
                .padding(.top, 4)
            VStack(spacing: 0) {
                ForEach(entries) { entry in
                    ActivityRow(entry: entry)
                    if entry.id != entries.last?.id { Divider().overlay(Theme.hairline) }
                }
            }
            .glassCard()
        }
    }

    // MARK: Actions

    private func enable(_ on: Bool) {
        let arrival = model.arrival
        if on {
            model.location.requestPermission()
            if arrival.settings.home == nil, let here = model.location.location {
                arrival.settings.home = Coordinate(here.coordinate)
            }
            if arrival.settings.notify { Task { await arrival.requestNotificationPermission() } }
        }
        withAnimation(.snappySpring) { arrival.settings.isEnabled = on }
        focusHome()
    }

    private func useCurrentLocation() {
        guard let here = model.location.location else { return }
        withAnimation(.snappySpring) { model.arrival.settings.home = Coordinate(here.coordinate) }
        focusHome()
    }

    private func focusHome() {
        guard let home = model.arrival.settings.home else { return }
        withAnimation(.softSpring) { camera = homeCamera(home) }
    }

    private func homeCamera(_ home: Coordinate) -> MapCameraPosition {
        .camera(MapCamera(centerCoordinate: home.clCoordinate, distance: max(900, radius * 5.5), heading: 0, pitch: 50))
    }

    private func runTest(_ transition: ZoneTransition) {
        runningTest = true
        Task {
            await model.arrival.runTest(transition)
            runningTest = false
        }
    }
}

// MARK: - Pieces

private struct HomePin: View {
    let isHome: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.cyan.opacity(0.7), lineWidth: 2)
                .frame(width: 44, height: 44)
                .scaleEffect(pulse ? 2.2 : 1)
                .opacity(pulse ? 0 : 0.9)
            Circle()
                .fill(isHome ? AnyShapeStyle(Theme.warmGradient) : AnyShapeStyle(Theme.cyan))
                .frame(width: 44, height: 44)
                .shadow(color: (isHome ? Theme.amber : Theme.cyan).opacity(0.8), radius: 12)
            Image(systemName: "house.fill")
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(.black.opacity(0.75))
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) { pulse = true }
        }
    }
}

private struct OptionRow<Trailing: View>: View {
    let symbol: String
    let title: Text
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 14) {
            IconBadge(symbol: symbol, color: Theme.cyan, size: 34)
            title.font(.body.weight(.medium)).foregroundStyle(.white)
            Spacer()
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }
}

private struct OptionLabel: View {
    let symbol: String
    let title: Text
    let subtitle: Text

    var body: some View {
        HStack(spacing: 14) {
            IconBadge(symbol: symbol, color: Theme.cyan, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                title.font(.body.weight(.medium)).foregroundStyle(.white)
                subtitle.font(.footnote).foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

struct ActivityRow: View {
    let entry: ActivityEntry

    var body: some View {
        HStack(spacing: 14) {
            IconBadge(symbol: entry.kind.symbol, color: color, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.message)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                Text(entry.date, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var color: Color {
        switch entry.kind {
        case .arrived: Theme.amber
        case .left: Theme.cyan
        case .test: Theme.mint
        case .skipped: Theme.textSecondary
        case .error: Theme.danger
        case .shortcut: Theme.mint
        }
    }
}

private struct PermissionCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    var body: some View {
        let location = model.location
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                IconBadge(symbol: "location.fill.viewfinder", color: Theme.cyan, size: 40)
                Text(title).font(.headline).foregroundStyle(.white)
            }
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                if location.isDenied {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                } else {
                    location.requestPermission()
                }
            } label: {
                Text(buttonTitle)
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.glassProminent)
            .tint(Theme.cyan.opacity(0.8))
        }
        .padding(18)
        .glassCard(tint: Theme.cyan.opacity(0.08))
    }

    private var title: LocalizedStringKey {
        switch model.location.authorization {
        case .authorizedWhenInUse: "Allow location “Always”"
        case .denied, .restricted: "Location is turned off"
        default: "Allow location access"
        }
    }

    private var message: LocalizedStringKey {
        switch model.location.authorization {
        case .authorizedWhenInUse:
            "To turn lights on while the app is closed, iOS needs location access set to “Always”."
        case .denied, .restricted:
            "Turn on location for AppleHome in Settings so it can tell when you arrive."
        default:
            "AppleHome uses your location only to notice when you enter or leave your home zone."
        }
    }

    private var buttonTitle: LocalizedStringKey {
        switch model.location.authorization {
        case .authorizedWhenInUse: "Allow Always"
        case .denied, .restricted: "Open Settings"
        default: "Continue"
        }
    }
}

private struct HomeKitAutomationCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let homeKit = model.homeKit
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                IconBadge(symbol: "homekit", color: Theme.amber, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Apple Home automation").font(.headline).foregroundStyle(.white)
                    Text(statusTitle).font(.subheadline.weight(.medium)).foregroundStyle(statusColor)
                }
                Spacer()
                if homeKit.automationStatus == .syncing { ProgressView().tint(.white) }
            }
            Text(statusDetail)
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                Task { await model.arrival.syncHomeKit() }
            } label: {
                Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 40)
            }
            .buttonStyle(.glass)
            .disabled(homeKit.home == nil || homeKit.automationStatus == .syncing)
        }
        .padding(18)
        .glassCard()
    }

    private var statusTitle: String {
        switch model.homeKit.automationStatus {
        case .idle: String(localized: "Not set up")
        case .syncing: String(localized: "Saving…")
        case .synced: String(localized: "Saved in Apple Home")
        case .noHub: String(localized: "Needs a home hub")
        case .failed: String(localized: "Couldn't save")
        }
    }

    private var statusColor: Color {
        switch model.homeKit.automationStatus {
        case .synced: Theme.mint
        case .noHub: Theme.amber
        case .failed: Theme.danger
        default: Theme.textSecondary
        }
    }

    private var statusDetail: String {
        switch model.homeKit.automationStatus {
        case .idle:
            model.homeKit.home == nil
                ? String(localized: "No Apple Home found. Set up a home in the Home app first.")
                : String(localized: "Turn on arrival lights and set your home to create the automation.")
        case .syncing: String(localized: "Updating the automation in Apple Home.")
        case .synced: String(localized: "Your home hub runs it, even when this app is closed.")
        case .noHub: String(localized: "The automation is saved, but it only runs with a home hub (Apple TV or HomePod) at home.")
        case .failed(let message): message
        }
    }
}
