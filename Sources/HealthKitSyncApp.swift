import SwiftUI

@main
struct HealthKitSyncApp: App {

    init() {
        // Observers are registered here rather than from a view.
        //
        // When HealthKit has new samples it relaunches this app straight into
        // the background, where no window and no view is ever created. An
        // observer registered from `.task` would therefore not exist on exactly
        // the launch that needed it, and the wake-up would be wasted.
        //
        // SwiftUI creates the `App` on the main thread, so assuming main-actor
        // isolation here is safe and avoids deferring registration to a later
        // hop — by which point iOS may already have suspended us again.
        MainActor.assumeIsolated {
            BackgroundSyncCoordinator.shared.registerObservers()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
