import SwiftUI
import Charts

/// One metric, full width, with the summary statistics the card has no room for.
struct MetricDetailView: View {
    let series: MetricSeries
    let range: DashboardModel.Range

    private var metric: HealthMetric { series.metric }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                MetricChart(series: series)
                    .frame(height: 240)
                    .padding(.horizontal)
                    .padding(.top, 8)

                statsGrid

                if !series.sources.isEmpty {
                    sourcesSection
                }
            }
            .padding(.vertical)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(metric.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var statsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            if metric.chartKind == .dailyTotal {
                stat("Total", series.total)
                stat("Daily average", series.average)
                stat("Best day", series.maximum)
                stat("Quietest day", series.minimum)
            } else {
                stat("Latest", series.latest?.value)
                stat("Average", series.average)
                stat("Highest", series.maximum)
                stat("Lowest", series.minimum)
            }
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private func stat(_ title: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let value {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(metric.format(value))
                        .font(.system(.title3, design: .rounded, weight: .semibold))
                    Text(metric.chartUnit)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("—").font(.title3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recorded by")
                .font(.caption)
                .foregroundStyle(.secondary)
            // Worth surfacing: the same metric legitimately arrives from both the
            // phone and the Watch, and seeing both names is what explains a step
            // count that looks doubled but is not.
            ForEach(series.sources, id: \.self) { source in
                Label(source, systemImage: source.localizedCaseInsensitiveContains("watch")
                      ? "applewatch" : "iphone")
                    .font(.subheadline)
            }
            Text("\(series.sampleCount) samples over the last \(range.days) days")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }
}
