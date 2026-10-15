import AppIntents

/// The API lights, offered wherever an intent asks for a light. Intents take the light's id
/// as a plain String with this as its picker, instead of an AppEntity: entity parameters
/// came through empty (in the widget extension and in Shortcuts alike), while plain ids work
/// everywhere.
struct LightOptions: DynamicOptionsProvider {
    func results() async throws -> ItemCollection<String> {
        let items = await LightRemote.lights().map {
            IntentItem($0.id, title: "\($0.name)", subtitle: $0.room.isEmpty ? nil : "\($0.room)")
        }
        return ItemCollection(sections: [ItemSection(items: items)])
    }
}
