import SwiftData
import SwiftUI
import TildeCore
import TildeStore

/// Sample data beyond `PreviewSeed` (which has no snippets): used by `AppEnvironment.mock()` and previews.
public enum TildePreview {
    /// An in-memory container with servers, groups, tags, a key and the 8 example snippets.
    @MainActor
    public static func container() -> ModelContainer {
        let container = ModelContainerFactory.preview()
        seedSnippets(container.mainContext)
        return container
    }

    @MainActor
    public static func seedSnippets(_ context: ModelContext) {
        for (index, snippet) in StaticSnippetProvider.seeded.enumerated() {
            let model = Snippet(name: snippet.name, command: snippet.command,
                                runModeRaw: snippet.runOnInsert ? "insertAndReturn" : "insert", seedID: "preview-\(index + 1)")
            model.id = snippet.id
            model.sortIndex = Double(index)
            context.insert(model)
        }
        try? context.save()
    }
}

/// Wraps previews with a model container, mock services, a coordinator and a navigator, and (optionally) opens a mock
/// session to `prod-api-01`.
struct TildePreviewHost<Content: View>: View {
    @State private var container = TildePreview.container()
    @State private var coordinator: SessionCoordinator
    @State private var navigator: AppNavigator
    private let services: TildeServices
    private let openSession: Bool
    private let content: (AppNavigator) -> Content

    init(sessionFailure: SessionError? = nil, openSession: Bool = true, @ViewBuilder content: @escaping (AppNavigator) -> Content) {
        var services = TildeServices.preview
        services.sessionEngine = FakeSessionEngine(failure: sessionFailure)
        let coordinator = SessionCoordinator(services: services)
        self.services = services
        self.openSession = openSession
        self.content = content
        _coordinator = State(initialValue: coordinator)
        _navigator = State(initialValue: coordinator.navigator(for: UUID()))
    }

    var body: some View {
        content(navigator)
            .environment(\.tildeServices, services)
            .environment(coordinator)
            .environment(navigator)
            .modelContainer(container)
            .preferredColorScheme(.dark)
            .task {
                if openSession, coordinator.tabs.isEmpty { navigator.open(PreviewServers.prodAPI) }
            }
    }
}
