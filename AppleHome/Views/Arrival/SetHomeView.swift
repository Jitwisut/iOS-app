import SwiftUI
import MapKit

/// Full-screen home picker: pan/zoom the map under a fixed center pin (like a ride-hailing
/// pickup picker), or search an address, then confirm explicitly. Nothing here moves the
/// pin from a stray tap — a home location only changes when "Set as home" is pressed.
struct SetHomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let onSet: (Coordinate) -> Void

    @State private var camera: MapCameraPosition = .automatic
    @State private var centerCoordinate = CLLocationCoordinate2D()
    @State private var searchText = ""
    @State private var searchResults: [MKMapItem] = []
    @State private var isSearching = false
    @State private var searchError = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        ZStack {
            Map(position: $camera, interactionModes: [.pan, .zoom, .rotate])
                .mapStyle(.standard(pointsOfInterest: .excludingAll))
                .onMapCameraChange(frequency: .continuous) { context in
                    centerCoordinate = context.region.center
                }
                .ignoresSafeArea()

            // Fixed at the exact screen center; the map moves underneath it, not this.
            Image(systemName: "mappin")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(Theme.amber)
                .shadow(color: .black.opacity(0.5), radius: 4, y: 2)
                .offset(y: -16)
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                topBar
                searchField
                if !searchResults.isEmpty { searchResultsList }
                Spacer()
                bottomControls
            }
        }
        .onAppear {
            let start = model.arrival.settings.home?.clCoordinate ?? model.location.location?.coordinate
            centerCoordinate = start ?? CLLocationCoordinate2D(latitude: 13.7563, longitude: 100.5018)
            camera = .region(MKCoordinateRegion(center: centerCoordinate, latitudinalMeters: 1200, longitudinalMeters: 1200))
        }
    }

    private var topBar: some View {
        HStack {
            Text("Set home")
                .font(.headline)
                .foregroundStyle(.white)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel(Text("Close"))
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.textSecondary)
            TextField(text: $searchText, prompt: Text("Search for an address")) { Text("Address") }
                .foregroundStyle(.white)
                .focused($searchFocused)
                .submitLabel(.search)
                .onSubmit(search)
            if isSearching {
                ProgressView().tint(.white)
            } else if !searchText.isEmpty {
                Button {
                    searchText = ""
                    searchResults = []
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    private var searchResultsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(searchResults.enumerated()), id: \.offset) { _, item in
                Button {
                    select(item)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name ?? String(localized: "Location"))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        if let address = item.placemark.formattedAddress {
                            Text(address)
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 44)
                }
                if item != searchResults.last { Divider().overlay(Theme.hairline) }
            }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var bottomControls: some View {
        VStack(spacing: 10) {
            if searchError {
                Text("Couldn't find that address.")
                    .font(.footnote)
                    .foregroundStyle(Theme.danger)
            }
            Button {
                guard let here = model.location.location else { return }
                withAnimation(.snappySpring) {
                    camera = .region(MKCoordinateRegion(center: here.coordinate, latitudinalMeters: 600, longitudinalMeters: 600))
                }
            } label: {
                Label("Use my location", systemImage: "location.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.glass)
            .tint(Theme.cyan)
            .disabled(model.location.location == nil)

            Button {
                onSet(Coordinate(centerCoordinate))
                dismiss()
            } label: {
                Label("Set as home", systemImage: "house.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.glassProminent)
            .tint(Theme.amber)
        }
        .padding(16)
        .padding(.bottom, 8)
    }

    private func search() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        searchFocused = false
        isSearching = true
        searchError = false
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = MKCoordinateRegion(center: centerCoordinate, latitudinalMeters: 50_000, longitudinalMeters: 50_000)
        Task {
            let response = try? await MKLocalSearch(request: request).start()
            searchResults = response?.mapItems ?? []
            searchError = searchResults.isEmpty
            isSearching = false
        }
    }

    private func select(_ item: MKMapItem) {
        withAnimation(.snappySpring) {
            camera = .region(MKCoordinateRegion(center: item.placemark.coordinate, latitudinalMeters: 600, longitudinalMeters: 600))
        }
        searchResults = []
        searchText = item.name ?? searchText
        searchFocused = false
    }
}

private extension MKPlacemark {
    /// A short, human-readable line for a search result's subtitle.
    var formattedAddress: String? {
        let parts = [thoroughfare, subLocality, locality].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}
