import SwiftUI
import SonosKit

@main
struct SonosBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // Menu bar app: everything lives in the status item popover (AppDelegate).
        // SwiftUI needs at least one scene.
        Settings { EmptyView() }
    }
}
