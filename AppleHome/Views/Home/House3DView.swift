import SwiftUI
import RealityKit

struct House3DView: View {
    var rooms: [RoomGlow]
    var selectedRoom: String?
    var onSelectRoom: (String?) -> Void

    @State private var scene = HouseScene()
    /// Decided on the first movement: horizontal spins the house, vertical scrolls the page.
    @State private var isRotating: Bool?

    var body: some View {
        RealityView { content in
            content.camera = .virtual
            content.add(scene.root)
            await scene.prepareLighting()
        } update: { _ in
            scene.sync(rooms: rooms, selected: selectedRoom)
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 10)
                .onChanged { value in
                    if isRotating == nil {
                        isRotating = abs(value.translation.width) > abs(value.translation.height)
                    }
                    if isRotating == true { scene.drag(by: value.translation) }
                }
                .onEnded { value in
                    if isRotating == true { scene.endDrag(predictedTranslation: value.predictedEndTranslation) }
                    isRotating = nil
                }
        )
        .simultaneousGesture(
            SpatialTapGesture()
                .targetedToAnyEntity()
                .onEnded { value in
                    let name = HouseScene.roomName(for: value.entity)
                    onSelectRoom(name == selectedRoom ? nil : name)
                }
        )
        .accessibilityElement()
        .accessibilityLabel(Text("3D model of your home"))
        .accessibilityValue(Text(accessibilitySummary))
    }

    private var accessibilitySummary: String {
        rooms.map { String(localized: "\($0.name): \($0.onCount) of \($0.total) on") }.joined(separator: ", ")
    }
}
