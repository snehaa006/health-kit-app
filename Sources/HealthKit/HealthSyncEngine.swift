import Foundation
import HealthKit
import Observation

/// One page of changes, already reduced to `Sendable` values.
///
/// `HKSample` and `HKQueryAnchor` are non-`Sendable` classes, so everything is
/// converted inside the HealthKit callback -- samples become rows, the anchor
/// becomes archived `Data` -- and only this struct leaves the query handler.
private struct SyncBatch: Sendable {
    let rows: [HealthSampleRow]
    let deletedUUIDs: [UUID]
    let anchorData: Data?
    /// Raw sample count, including any the mapper skipped. Compared against the
    /// page size to decide whether another page exists.
    let addedCount: Int
}

@MainActor
@Observable
final class HealthSyncEngine {

    static let shared = HealthSyncEngine()

    enum Status: Equatable {
        case idle
        case syncing(HealthMetric)
        case finished(uploaded: Int, deleted: Int, at: Date)
        case failed(String)
    }

    private(set) var status: Status = .idle
    private(set) var isSyncing = false

    /// Mirrors the anchor store's per-metric display state.
    ///
    /// `SyncAnchorStore` is backed by `UserDefaults`, which SwiftUI's observation
    /// system cannot see: writing a date there updated nothing on screen, which
    /// is why every row still read "Never" after a sync that had plainly worked.
    /// Holding the same values as observed properties is what makes the list
    /// refresh -- the store stays the source of truth across launches.
    private(set) var lastSyncDates: [HealthMetric: Date] = [:]
    private(set) var syncedCounts: [HealthMetric: Int] = [:]

    let anchors = SyncAnchorStore()

    private let health = HealthKitManager.shared
    private let supabase = SupabaseService.shared

    /// Defensive bound on the pagination loop: 200 pages of 5,000 is a million
    /// samples, far past any real 30-day window, so hitting it means something
    /// is wrong rather than merely large.
    private let maxPagesPerMetric = 200

    private init() {
        reloadDisplayState()
    }

    /// Re-reads the persisted per-metric state into the observed properties.
    private func reloadDisplayState() {
        var dates: [HealthMetric: Date] = [:]
        var counts: [HealthMetric: Int] = [:]
        for metric in HealthMetric.allCases {
            dates[metric] = anchors.lastSync(for: metric)
            counts[metric] = anchors.syncedCount(for: metric)
        }
        lastSyncDates = dates
        syncedCounts = counts
    }

    // MARK: - Entry point

    func syncAll() async {
        guard !isSyncing else { return }
        guard health.isAvailable else {
            status = .failed("HealthKit isn't available on this device.")
            return
        }
        guard let patientID = supabase.userID else {
            status = .failed("Sign in to Supabase before syncing.")
            return
        }

        isSyncing = true
        defer { isSyncing = false }

        var uploaded = 0
        var deleted = 0

        for metric in HealthMetric.allCases {
            status = .syncing(metric)
            do {
                let result = try await sync(metric, patientID: patientID)
                uploaded += result.uploaded
                deleted += result.deleted
            } catch {
                // Anchors for metrics that already finished stay saved, so a
                // failure here costs only the remaining metrics -- the next run
                // resumes rather than restarting.
                status = .failed("\(metric.displayName): \(Self.readable(error))")
                return
            }
        }

        status = .finished(uploaded: uploaded, deleted: deleted, at: Date())
    }

    // MARK: - Per-metric sync

    private func sync(
        _ metric: HealthMetric,
        patientID: UUID
    ) async throws -> (uploaded: Int, deleted: Int) {

        // The same predicate on every run. The anchor records a position in
        // HealthKit's insert order; pairing it with a *moving* date window would
        // let samples fall between the two, so the window is pinned once at
        // first launch and reused verbatim.
        let predicate = HKQuery.predicateForSamples(
            withStart: anchors.historyStart(window: SupabaseConfig.initialHistoryWindow),
            end: nil,
            options: .strictStartDate
        )

        var anchor = anchors.anchor(for: metric)
        var uploaded = 0
        var deleted = 0

        for _ in 0 ..< maxPagesPerMetric {
            let batch = try await fetchPage(
                metric: metric,
                anchor: anchor,
                predicate: predicate,
                patientID: patientID
            )

            // Upload first, advance the anchor second. The reverse order loses
            // data permanently: the anchor would say "delivered" for samples
            // that never reached Supabase, and HealthKit never replays them.
            try await supabase.upsert(batch.rows)
            try await supabase.delete(healthKitUUIDs: batch.deletedUUIDs, patientID: patientID)

            uploaded += batch.rows.count
            deleted += batch.deletedUUIDs.count

            // No anchor back means no way to advance; stopping here beats
            // looping on the same page.
            guard let anchorData = batch.anchorData else { break }
            anchors.setAnchorData(anchorData, for: metric)
            anchor = SyncAnchorStore.unarchive(anchorData)

            // A short page is HealthKit saying there is nothing left.
            if batch.addedCount < SupabaseConfig.fetchPageSize { break }
        }

        anchors.recordSync(for: metric, date: Date(), newRows: uploaded)
        reloadDisplayState()
        return (uploaded, deleted)
    }

    // MARK: - HealthKit

    private func fetchPage(
        metric: HealthMetric,
        anchor: HKQueryAnchor?,
        predicate: NSPredicate,
        patientID: UUID
    ) async throws -> SyncBatch {
        let store = health.store
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKAnchoredObjectQuery(
                type: metric.sampleType,
                predicate: predicate,
                anchor: anchor,
                limit: SupabaseConfig.fetchPageSize
            ) { _, samples, deletedObjects, newAnchor, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let samples = samples ?? []
                continuation.resume(
                    returning: SyncBatch(
                        rows: HealthSampleRow.rows(from: samples, metric: metric, patientID: patientID),
                        deletedUUIDs: (deletedObjects ?? []).map(\.uuid),
                        anchorData: newAnchor.flatMap(SyncAnchorStore.archive),
                        addedCount: samples.count
                    )
                )
            }
            store.execute(query)
        }
    }

    // MARK: - Errors

    private static func readable(_ error: Error) -> String {
        let message = "\(error)"
        if message.contains("PGRST205") || message.localizedCaseInsensitiveContains("schema cache") {
            return "The health_samples table doesn't exist yet. Run supabase/schema.sql in the Supabase SQL Editor."
        }
        if message.contains("42501") || message.localizedCaseInsensitiveContains("row-level security") {
            return "Row Level Security rejected the write. Check that you're signed in and that the RLS policies from schema.sql were created."
        }
        return error.localizedDescription
    }
}
