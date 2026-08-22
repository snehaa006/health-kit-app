import SwiftUI
import Charts

/// Reads back what actually reached Supabase, rather than querying HealthKit
/// again. That makes the charts a check on the sync as well as a view of the
/// data: if a chart looks right, the round trip worked.
struct DashboardView: View {

    @State private var model = DashboardModel()

    var body: some View {
        @Bindable var model = model

        ScrollView {
            VStack(spacing: 16) {
                Picker("Range", selection: $model.range) {
                    ForEach(DashboardModel.Range.allCases) { range in
                        Text(range.rawValue).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                content
            }
            .padding(.vertical, 8)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Dashboard")
        .task { await model.load() }
        .refreshable { await model.load() }
        .onChange(of: model.range) {
            Task { await model.load() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading && model.series.isEmpty {
            ProgressView("Loading…")
                .padding(.top, 80)

        } else if let error = model.errorMessage {
            ContentUnavailableView {
                Label("Couldn't load", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") { Task { await model.load() } }
            }
            .padding(.top, 40)

        } else {
            ForEach(model.populatedGroups) { grouped in
                VStack(alignment: .leading, spacing: 10) {
                    Text(grouped.group.rawValue)
                        .font(.title3.weight(.semibold))
                        .padding(.horizontal, 20)
                        .padding(.top, 8)

                    ForEach(grouped.series) { series in
                        NavigationLink {
                            MetricDetailView(series: series, range: model.range)
                        } label: {
                            MetricCard(series: series)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if model.populatedGroups.isEmpty {
                ContentUnavailableView(
                    "Nothing synced yet",
                    systemImage: "heart.text.square",
                    description: Text("Tap Sync Now to send your Health data to Supabase.")
                )
                .padding(.top, 40)
            }

            if !model.emptyMetrics.isEmpty {
                emptySection
            }

            if let loaded = model.lastLoaded {
                Text("Updated \(loaded.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
        }
    }

    /// Collapsed rather than hidden: most people will have no data for most of
    /// these, and a metric that produced nothing is worth being able to check.
    private var emptySection: some View {
        DisclosureGroup {
            VStack(spacing: 0) {
                ForEach(model.emptyMetrics) { metric in
                    HStack {
                        Label(metric.displayName, systemImage: metric.symbolName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.vertical, 8)
                }
            }
        } label: {
            Text("\(model.emptyMetrics.count) with no data")
                .font(.subheadline.weight(.medium))
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal)
        .padding(.top, 8)
    }
}

// MARK: - Card

struct MetricCard: View {
    let series: MetricSeries

    private var metric: HealthMetric { series.metric }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label(metric.displayName, systemImage: metric.symbolName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(metric.tint)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }

            if let headline = series.headline {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(metric.format(headline))
                        .font(.system(.title, design: .rounded, weight: .semibold))
                        .contentTransition(.numericText())
                    Text(metric.chartUnit)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(series.headlineCaption)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            MetricChart(series: series, showsAxes: false)
                .frame(height: 90)

            Text(footnote)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal)
    }

    private var footnote: String {
        let samples = "\(series.sampleCount) sample\(series.sampleCount == 1 ? "" : "s")"
        guard !series.sources.isEmpty else { return samples }
        return "\(samples) · \(series.sources.joined(separator: ", "))"
    }
}

// MARK: - Chart

/// The one place a metric turns into marks.
///
/// Split into two `Chart` bodies rather than branching inside a single content
/// builder: bars and lines want different axes and a different y-domain, and
/// forcing both through one builder makes each harder to read than it needs to be.
struct MetricChart: View {
    let series: MetricSeries
    var showsAxes: Bool = true

    private var metric: HealthMetric { series.metric }

    var body: some View {
        Group {
            if metric.chartKind == .dailyTotal {
                barChart
            } else {
                lineChart
            }
        }
        .chartXAxis { if showsAxes { AxisMarks(preset: .aligned) } }
        .chartYAxis { if showsAxes { AxisMarks(position: .leading) } }
    }

    private var barChart: some View {
        Chart(series.points) { point in
            BarMark(
                x: .value("Day", point.date, unit: .day),
                y: .value(metric.displayName, point.value)
            )
            .foregroundStyle(metric.tint.gradient)
            .cornerRadius(3)
        }
    }

    private var lineChart: some View {
        Chart(series.points) { point in
            AreaMark(
                x: .value("Time", point.date),
                y: .value(metric.displayName, point.value)
            )
            .foregroundStyle(metric.tint.opacity(0.15).gradient)
            .interpolationMethod(.catmullRom)

            LineMark(
                x: .value("Time", point.date),
                y: .value(metric.displayName, point.value)
            )
            .foregroundStyle(metric.tint)
            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
            .interpolationMethod(.catmullRom)
        }
        // Rates never start at zero: a heart-rate chart anchored to 0 squashes
        // the entire day into the top fifth of the plot and hides the variation
        // that is the whole point of looking.
        .chartYScale(domain: .automatic(includesZero: false))
    }
}
