import GameController
import SwiftUI

/// Hosts SwiftUI content inside a GCEventViewController so controller buttons (including Menu)
/// go only to the Game Controller framework while flying, instead of navigating or closing the app.
/// Pass `allowsSystemNavigation: true` (for example on an error screen) to give buttons back to SwiftUI focus navigation.
struct GameControllerHost<Content: View>: UIViewControllerRepresentable {
    var allowsSystemNavigation = false
    @ViewBuilder let content: () -> Content

    func makeUIViewController(context: Context) -> GCEventViewController {
        let controller = GCEventViewController()
        controller.controllerUserInteractionEnabled = allowsSystemNavigation
        let hosting = UIHostingController(rootView: content())
        hosting.view.backgroundColor = .black
        controller.addChild(hosting)
        hosting.view.frame = controller.view.bounds
        hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controller.view.addSubview(hosting.view)
        hosting.didMove(toParent: controller)
        context.coordinator.hosting = hosting
        return controller
    }

    func updateUIViewController(_ controller: GCEventViewController, context: Context) {
        controller.controllerUserInteractionEnabled = allowsSystemNavigation
        context.coordinator.hosting?.rootView = content()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var hosting: UIHostingController<Content>?
    }
}
