import Foundation
import HealthKit

/// Persists one `HKQueryAnchor` per metric, plus the timestamps the UI shows.
///
/// Anchors are stored as archived `Data` rather than as live objects. That is
/// partly because `HKQueryAnchor` is only expressible via `NSSecureCoding`, and
/// partly because `Data` is `Sendable` -- the sync engine moves anchors off the
/// HealthKit callback queue, and archiving at the boundary avoids passing a
/// non-`Sendable` class across it.
/// `@unchecked Sendable` because `UserDefaults` carries no `Sendable` conformance
/// while being documented as thread-safe. The conformance matters from Step 4 on:
/// background delivery invokes the sync engine from outside the main actor, and
/// the anchor store travels with it.
struct SyncAnchorStore: @unchecked Sendable {

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Keys

    private func anchorKey(_ metric: HealthMetric) -> String { "sync.anchor.\(metric.rawValue)" }
    private func lastSyncKey(_ metric: HealthMetric) -> String { "sync.lastDate.\(metric.rawValue)" }
    private func countKey(_ metric: HealthMetric) -> String { "sync.count.\(metric.rawValue)" }
    private static let historyStartKey = "sync.historyStart"

    // MARK: - Anchors

    func anchorData(for metric: HealthMetric) -> Data? {
        defaults.data(forKey: anchorKey(metric))
    }

    func anchor(for metric: HealthMetric) -> HKQueryAnchor? {
        guard let data = anchorData(for: metric) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }

    /// Call this **only after** the corresponding rows have been accepted by
    /// Supabase. Advancing the anchor is what tells HealthKit "I have these" --
    /// doing it before a successful upload silently drops those samples forever,
    /// because the next query starts after them and nothing ever replays.
    func setAnchorData(_ data: Data, for metric: HealthMetric) {
        defaults.set(data, forKey: anchorKey(metric))
    }

    static func archive(_ anchor: HKQueryAnchor) -> Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)
    }

    static func unarchive(_ data: Data) -> HKQueryAnchor? {
        try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }

    // MARK: - Display state

    func lastSync(for metric: HealthMetric) -> Date? {
        defaults.object(forKey: lastSyncKey(metric)) as? Date
    }

    func syncedCount(for metric: HealthMetric) -> Int {
        defaults.integer(forKey: countKey(metric))
    }

    func recordSync(for metric: HealthMetric, date: Date, newRows: Int) {
        defaults.set(date, forKey: lastSyncKey(metric))
        defaults.set(syncedCount(for: metric) + newRows, forKey: countKey(metric))
    }

    // MARK: - History window

    /// Fixed at first launch and never moved. The anchored queries always carry
    /// the same date predicate, so the anchor and the predicate stay consistent
    /// with each other across runs.
    func historyStart(window: TimeInterval) -> Date {
        if let existing = defaults.object(forKey: Self.historyStartKey) as? Date {
            return existing
        }
        let start = Date().addingTimeInterval(-window)
        defaults.set(start, forKey: Self.historyStartKey)
        return start
    }

    // MARK: - Reset

    /// Clears all anchors so the next sync re-reads the whole history window.
    /// Rows already in Supabase are upserted, not duplicated.
    func reset() {
        for metric in HealthMetric.allCases {
            defaults.removeObject(forKey: anchorKey(metric))
            defaults.removeObject(forKey: lastSyncKey(metric))
            defaults.removeObject(forKey: countKey(metric))
        }
        defaults.removeObject(forKey: Self.historyStartKey)
    }
}
