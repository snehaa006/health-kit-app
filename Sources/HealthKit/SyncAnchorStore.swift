import Foundation
import HealthKit

/// How far back a sync reaches.
///
/// This is a *sync* setting, not a display filter: it decides what is ever
/// pulled out of HealthKit in the first place, so nothing outside the chosen
/// window exists in Supabase to chart later.
enum HistoryWindow: String, CaseIterable, Identifiable, Sendable {
    case month       = "30 Days"
    case threeMonths = "3 Months"
    case sixMonths   = "6 Months"
    case year        = "1 Year"
    case fiveYears   = "5 Years"
    case everything  = "Everything"

    var id: String { rawValue }

    /// `nil` means no lower bound at all -- every sample HealthKit still holds.
    var days: Int? {
        switch self {
        case .month:       return 30
        case .threeMonths: return 90
        case .sixMonths:   return 180
        case .year:        return 365
        case .fiveYears:   return 365 * 5
        case .everything:  return nil
        }
    }

    /// Rough warning for the UI. Heart rate alone is a sample every few seconds
    /// while a workout runs, so a year is not four times a quarter -- it is
    /// whatever the person actually wore the Watch for.
    var isLarge: Bool {
        switch self {
        case .month, .threeMonths: return false
        default:                   return true
        }
    }
}

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
    private static let windowKey = "sync.historyWindow"

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

    var window: HistoryWindow {
        guard
            let raw = defaults.string(forKey: Self.windowKey),
            let stored = HistoryWindow(rawValue: raw)
        else { return .month }
        return stored
    }

    /// Widening the window is a deliberate re-read, not a filter change.
    ///
    /// An anchor records a position in HealthKit's delivery order, and samples
    /// older than the previous window sit *behind* that position. Simply
    /// widening the predicate would never surface them: the anchor has already
    /// moved past, and HealthKit only ever hands back what comes after it. So
    /// every anchor is cleared and the next sync walks the new window from
    /// scratch.
    ///
    /// Re-reading is safe precisely because uploads upsert on
    /// (patient_id, healthkit_uuid) -- rows already in Supabase update in place
    /// rather than duplicating.
    func setWindow(_ newWindow: HistoryWindow) {
        guard newWindow != window else { return }
        defaults.set(newWindow.rawValue, forKey: Self.windowKey)

        // The pinned start and every anchor belong to the *old* window.
        defaults.removeObject(forKey: Self.historyStartKey)
        for metric in HealthMetric.allCases {
            defaults.removeObject(forKey: anchorKey(metric))
        }
        _ = historyStart()
    }

    /// Fixed when the window is chosen and not moved again until it changes.
    /// The anchored queries always carry the same date predicate, so the anchor
    /// and the predicate stay consistent with each other across runs -- a
    /// *moving* window would let samples fall between the two.
    ///
    /// `nil` means an unbounded query: no start predicate at all.
    func historyStart() -> Date? {
        guard let days = window.days else { return nil }
        if let existing = defaults.object(forKey: Self.historyStartKey) as? Date {
            return existing
        }
        let start = Calendar.current.date(byAdding: .day, value: -days, to: Date())
            ?? Date().addingTimeInterval(-Double(days) * 86_400)
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
