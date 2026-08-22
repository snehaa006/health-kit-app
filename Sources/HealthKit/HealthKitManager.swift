import Foundation
import HealthKit
import Observation

/// Owns the app's single `HKHealthStore` and handles read authorization.
///
/// Pinned to the main actor so SwiftUI can read its state directly. HealthKit's
/// own callbacks arrive on background queues; each one hops back here before
/// touching any state.
@MainActor
@Observable
final class HealthKitManager {

    static let shared = HealthKitManager()

    enum AuthState: Equatable {
        /// HealthKit isn't supported on this hardware (iPad, Mac, some simulators).
        case unavailable
        /// The permission sheet has never been shown for this set of types.
        case notDetermined
        /// The sheet is on screen right now.
        case requesting
        /// The sheet has been shown and dismissed. Whether reads were *granted*
        /// is deliberately unknowable — see `probeReadAccess()`.
        case requested
        case failed(String)
    }

    let isAvailable = HKHealthStore.isHealthDataAvailable()

    private(set) var authState: AuthState
    /// Metrics that returned at least one sample on the most recent probe.
    private(set) var metricsWithData: Set<HealthMetric> = []
    private(set) var lastProbeDate: Date?
    private(set) var isProbing = false

    let store = HKHealthStore()

    private var readTypes: Set<HKObjectType> {
        Set(HealthMetric.allCases.map { $0.sampleType as HKObjectType })
    }

    private init() {
        authState = HKHealthStore.isHealthDataAvailable() ? .notDetermined : .unavailable
    }

    // MARK: - Authorization

    /// Asks HealthKit whether showing the sheet would accomplish anything.
    /// `.unnecessary` means every type has already been decided — it does *not*
    /// mean they were granted.
    func refreshRequestStatus() async {
        guard isAvailable else {
            authState = .unavailable
            return
        }
        do {
            let status = try await requestStatus()
            authState = (status == .shouldRequest) ? .notDetermined : .requested
        } catch {
            authState = .failed(error.localizedDescription)
        }
    }

    func requestAuthorization() async {
        guard isAvailable else {
            authState = .unavailable
            return
        }
        authState = .requesting
        do {
            // `toShare` is empty on purpose: this app only ever reads. Requesting
            // write access we don't need adds a second column of switches to the
            // permission sheet and is a red flag in App Review.
            try await store.requestAuthorization(toShare: [], read: readTypes)
            authState = .requested
            await probeReadAccess()
        } catch {
            authState = .failed(error.localizedDescription)
        }
    }

    // MARK: - Read-access probe

    /// HealthKit will not tell you whether a *read* was authorized.
    ///
    /// `authorizationStatus(for:)` reports share (write) permission only, and
    /// returns `.sharingDenied` for read-only types no matter what the user
    /// chose. That's intentional — otherwise an app could infer "this user has
    /// no heart data" from a denial, which is itself health information.
    ///
    /// The one observable signal is whether queries return anything. That is
    /// ambiguous (denied and "genuinely no samples yet" look identical), so the
    /// UI reports *data visible / nothing visible* rather than granted/denied.
    func probeReadAccess() async {
        guard isAvailable else { return }
        isProbing = true
        defer { isProbing = false }

        var found: Set<HealthMetric> = []
        for metric in HealthMetric.allCases {
            if await hasAnySample(of: metric) {
                found.insert(metric)
            }
        }
        metricsWithData = found
        lastProbeDate = Date()
    }

    /// Cheapest possible existence check: newest single sample, no predicate.
    private func hasAnySample(of metric: HealthMetric) async -> Bool {
        await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: metric.sampleType,
                predicate: nil,
                limit: 1,
                sortDescriptors: [
                    NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
                ]
            ) { _, samples, _ in
                continuation.resume(returning: samples?.isEmpty == false)
            }
            store.execute(query)
        }
    }

    private func requestStatus() async throws -> HKAuthorizationRequestStatus {
        try await withCheckedThrowingContinuation { continuation in
            store.getRequestStatusForAuthorization(toShare: [], read: readTypes) { status, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: status)
                }
            }
        }
    }
}
