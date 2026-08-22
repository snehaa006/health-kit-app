import Foundation
import Observation

/// One plotted point: either a single reading, or a whole day's total.
struct ChartPoint: Identifiable, Sendable, Equatable {
    var id: Date { date }
    let date: Date
    let value: Double
}

/// Everything the dashboard needs to draw one metric.
struct MetricSeries: Identifiable, Sendable {
    let metric: HealthMetric
    let points: [ChartPoint]
    /// Rows returned by Supabase, before any daily bucketing -- so the card can
    /// say "870 samples" even when the chart shows 30 bars.
    let sampleCount: Int
    let sources: [String]

    var id: String { metric.rawValue }
    var isEmpty: Bool { points.isEmpty }

    var total: Double { points.reduce(0) { $0 + $1.value } }
    var average: Double? { points.isEmpty ? nil : total / Double(points.count) }
    var minimum: Double? { points.map(\.value).min() }
    var maximum: Double? { points.map(\.value).max() }
    var latest: ChartPoint? { points.last }

    /// The number the card leads with. A total is the honest headline for
    /// something cumulative; for a rate, the most recent reading is.
    var headline: Double? {
        switch metric.chartKind {
        case .dailyTotal: return points.isEmpty ? nil : total
        case .reading:    return latest?.value
        }
    }

    var headlineCaption: String {
        switch metric.chartKind {
        case .dailyTotal: return "total"
        case .reading:    return "latest"
        }
    }
}

extension MetricSeries {

    /// Above this many readings a line chart stops being legible and starts
    /// being slow -- Swift Charts draws every mark it is handed.
    private static let downsampleThreshold = 600

    init(metric: HealthMetric, rows: [HealthSampleReading], calendar: Calendar) {
        // Sleep arrives as overlapping samples: HealthKit nests the asleep
        // stages inside an enclosing `inBed` interval, so totalling every row
        // would count most of a night twice. Only the asleep stages contribute.
        let rows = metric == .sleepAnalysis
            ? rows.filter {
                guard let value = $0.metadata?.categoryValue else { return false }
                return HealthMetric.asleepCategoryValues.contains(value)
            }
            : rows

        let values: [(Date, Double)] = rows.compactMap { row in
            guard let value = row.value else { return nil }
            return (row.startDate, metric.chartValue(value))
        }

        switch metric.chartKind {
        case .dailyTotal:
            var byDay: [Date: Double] = [:]
            for (date, value) in values {
                byDay[calendar.startOfDay(for: date), default: 0] += value
            }
            points = byDay
                .map { ChartPoint(date: $0.key, value: $0.value) }
                .sorted { $0.date < $1.date }

        case .reading:
            let raw = values.map { ChartPoint(date: $0.0, value: $0.1) }
            // A month of heart rate is tens of thousands of samples. Averaging
            // into hourly buckets keeps the shape of the day and drops the
            // per-second jitter that no one can read anyway.
            points = raw.count > Self.downsampleThreshold
                ? Self.hourlyAverages(raw, calendar: calendar)
                : raw
        }

        self.metric = metric
        self.sampleCount = rows.count
        self.sources = Set(rows.compactMap(\.source)).sorted()
    }

    private static func hourlyAverages(_ points: [ChartPoint], calendar: Calendar) -> [ChartPoint] {
        var buckets: [Date: (sum: Double, count: Int)] = [:]
        for point in points {
            let hour = calendar.dateInterval(of: .hour, for: point.date)?.start ?? point.date
            let existing = buckets[hour] ?? (0, 0)
            buckets[hour] = (existing.sum + point.value, existing.count + 1)
        }
        return buckets
            .map { ChartPoint(date: $0.key, value: $0.value.sum / Double($0.value.count)) }
            .sorted { $0.date < $1.date }
    }
}

/// One dashboard section: a group and the metrics in it that have data.
struct GroupedSeries: Identifiable {
    let group: HealthMetric.Group
    let series: [MetricSeries]
    var id: String { group.rawValue }
}

/// Loads the dashboard's data and shapes it for the charts.
@MainActor
@Observable
final class DashboardModel {

    private(set) var series: [MetricSeries] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var lastLoaded: Date?

    /// Shares `HistoryWindow` with the sync rather than defining a parallel set
    /// of ranges: the dashboard can only ever show what was actually pulled out
    /// of HealthKit, so the two should not be able to drift apart.
    var range: HistoryWindow = .month

    /// Metrics that returned data, bundled into their dashboard sections.
    /// A flat list of 38 cards is unusable, and for any given person most of
    /// them will be empty.
    var populatedGroups: [GroupedSeries] {
        HealthMetric.Group.allCases.compactMap { group in
            let members = series.filter { $0.metric.group == group && !$0.isEmpty }
            return members.isEmpty ? nil : GroupedSeries(group: group, series: members)
        }
    }

    /// Everything that came back empty, kept out of the way but not hidden --
    /// knowing a metric produced nothing is worth something.
    var emptyMetrics: [HealthMetric] {
        series.filter(\.isEmpty).map(\.metric)
    }

    private let supabase = SupabaseService.shared

    func load() async {
        guard let patientID = supabase.userID else {
            series = []
            errorMessage = "Sign in to see your data."
            return
        }

        isLoading = true
        defer { isLoading = false }
        errorMessage = nil

        let calendar = Calendar.current
        let since = range.days
            .flatMap { calendar.date(byAdding: .day, value: -$0, to: Date()) }
            ?? Date.distantPast

        do {
            let rows = try await supabase.fetchSamples(since: since, patientID: patientID)
            let byType = Dictionary(grouping: rows, by: \.type)
            // Every metric gets a series, including the ones with nothing in
            // them -- a visible "No data yet" is information, whereas silently
            // omitting the row leaves you wondering whether it synced at all.
            series = HealthMetric.allCases.map { metric in
                MetricSeries(metric: metric, rows: byType[metric.rawValue] ?? [], calendar: calendar)
            }
            lastLoaded = Date()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
