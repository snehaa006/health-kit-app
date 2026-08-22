import Foundation
import HealthKit
import Observation

/// Keeps the sync running without anyone tapping a button.
///
/// Two separate mechanisms have to line up for this to work, and neither is
/// sufficient alone:
///
/// 1. `enableBackgroundDelivery` tells HealthKit it may wake this app when new
///    samples land. It persists across launches and installs.
/// 2. An `HKObserverQuery` per type is what actually receives the wake-up. These
///    do *not* persist — they must be re-registered on every launch, including
///    the background launches HealthKit itself triggers.
///
/// The entitlement `com.apple.developer.healthkit.background-delivery` is
/// required for any of it, and is declared in project.yml.
@MainActor
@Observable
final class BackgroundSyncCoordinator {

    static let shared = BackgroundSyncCoordinator()

    private(set) var isEnabled = false
    private(set) var enabledTypeCount = 0
    private(set) var lastError: String?

    /// Persisted rather than held in memory: the whole point is that syncs happen
    /// in background launches, and the process may be torn down before anyone
    /// opens the app to look.
    private(set) var lastBackgroundSync: Date? {
        didSet { UserDefaults.standard.set(lastBackgroundSync, forKey: Self.lastSyncKey) }
    }

    private static let lastSyncKey = "background.lastSync"

    private var observerQueries: [HKObserverQuery] = []

    /// Guards against 37 observers firing at once and starting 37 syncs.
    private var isHandling = false
    private var changedWhileHandling = false

    private var store: HKHealthStore { HealthKitManager.shared.store }

    private init() {
        lastBackgroundSync = UserDefaults.standard.object(forKey: Self.lastSyncKey) as? Date
    }

    // MARK: - Registration

    /// Registers one observer per metric.
    ///
    /// Called from the app's `init`, not from a view's `.task`: HealthKit
    /// relaunches the app directly into the background, where no view is ever
    /// created, so an observer registered from a view would not exist on the one
    /// launch that actually needed it.
    func registerObservers() {
        guard HealthKitManager.shared.isAvailable, observerQueries.isEmpty else { return }

        for metric in HealthMetric.allCases {
            let query = HKObserverQuery(
                sampleType: metric.sampleType,
                predicate: nil
            ) { _, completionHandler, error in
                Task { @MainActor in
                    // The completion handler is what tells HealthKit the wake-up
                    // was handled. Failing to call it -- or taking too long --
                    // makes iOS back off and eventually stop delivering
                    // altogether, so it runs on every path including failure.
                    defer { completionHandler() }
                    if let error {
                        BackgroundSyncCoordinator.shared.lastError = error.localizedDescription
                        return
                    }
                    await BackgroundSyncCoordinator.shared.handleObservedChange()
                }
            }
            store.execute(query)
            observerQueries.append(query)
        }
    }

    /// Asks HealthKit to wake the app when new samples arrive.
    ///
    /// Enabled per type and tolerant of individual failures: not every sample
    /// type supports background delivery, and one refusal should not cost the
    /// other thirty-six.
    func enableBackgroundDelivery() async {
        guard HealthKitManager.shared.isAvailable else { return }

        var enabled = 0
        var firstFailure: String?

        for metric in HealthMetric.allCases {
            do {
                // `.immediate` is a request, not a guarantee -- HealthKit clamps
                // most types to at most hourly, and batches quietly to protect
                // the battery.
                try await store.enableBackgroundDelivery(
                    for: metric.sampleType,
                    frequency: .immediate
                )
                enabled += 1
            } catch {
                if firstFailure == nil {
                    firstFailure = "\(metric.displayName): \(error.localizedDescription)"
                }
            }
        }

        enabledTypeCount = enabled
        isEnabled = enabled > 0
        lastError = enabled == 0 ? firstFailure : nil

        registerObservers()
    }

    // MARK: - Handling

    /// Runs a sync in response to a HealthKit wake-up.
    ///
    /// The `repeat` loop matters: a change arriving *while* a sync is running
    /// would otherwise be dropped, because `syncAll` returns immediately when it
    /// is already busy. Looping once more picks it up instead of waiting for the
    /// next unrelated change to come along.
    func handleObservedChange() async {
        guard !isHandling else {
            changedWhileHandling = true
            return
        }
        isHandling = true
        defer { isHandling = false }

        // A background launch starts with no session in memory. Without this the
        // sync would fail on "Sign in to Supabase before syncing" every time,
        // even though the session is sitting in the Keychain.
        if SupabaseService.shared.userID == nil {
            await SupabaseService.shared.restore()
        }
        guard SupabaseService.shared.userID != nil else {
            lastError = "Signed out — background sync paused."
            return
        }

        repeat {
            changedWhileHandling = false
            await HealthSyncEngine.shared.syncAll()
        } while changedWhileHandling

        lastBackgroundSync = Date()
    }
}
