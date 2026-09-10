import SwiftUI
import RealityKit

struct House3DView: View {
    var rooms: [RoomGlow]
    var selectedRoom: String?
    var onSelectRoom: (String?) -> Void

    @State private var scene = HouseScene()

    var body: some View {
        RealityView { content in
            content.camera = .virtual
            content.add(scene.root)
            await scene.prepareLighting()
        } update: { _ in
            scene.sync(rooms: rooms, selected: selectedRoom)
        }
        .gesture(
            DragGesture(minimumDistance: 6)
                .onChanged { scene.drag(by: $0.translation) }
                .onEnded { scene.endDrag(predictedTranslation: $0.predictedEndTranslation) }
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
