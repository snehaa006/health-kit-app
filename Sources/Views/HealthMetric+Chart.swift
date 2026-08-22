import SwiftUI

/// Charting details for each metric.
///
/// Kept as an extension in the view layer rather than folded into
/// `HealthMetric` itself: the sync engine runs in the background and has no
/// business importing SwiftUI, so the domain type stays free of view concerns.
extension HealthMetric {

    /// How a metric reads best over time.
    enum ChartKind: Equatable {
        /// Summed into one bar per day. Counts and totals are meaningless as
        /// individual samples -- HealthKit records steps in bursts of a few
        /// seconds, so plotting raw samples draws noise rather than a day's
        /// activity.
        case dailyTotal
        /// Drawn as individual readings. Rates and instantaneous measurements
        /// would be destroyed by summing: a day of heart rate does not add up to
        /// anything a person would recognise.
        case reading
    }

    var chartKind: ChartKind {
        switch self {
        case .stepCount, .activeEnergyBurned, .workout:
            return .dailyTotal
        case .heartRate, .oxygenSaturation, .heartRateVariabilitySDNN:
            return .reading
        }
    }

    var tint: Color {
        switch self {
        case .heartRate:                return .pink
        case .stepCount:                return .green
        case .activeEnergyBurned:       return .orange
        case .oxygenSaturation:         return .cyan
        case .heartRateVariabilitySDNN: return .purple
        case .workout:                  return .indigo
        }
    }

    /// Workout duration is stored in seconds because that is what `HKWorkout`
    /// reports, but a bar 3,600 tall says less than one labelled 60 min.
    var chartUnit: String {
        self == .workout ? "min" : unitLabel
    }

    func chartValue(_ stored: Double) -> Double {
        self == .workout ? stored / 60 : stored
    }

    /// Decimal places that suit the metric: a fractional step is nonsense, while
    /// a whole-number SpO2 throws away the only variation the reading has.
    func format(_ value: Double) -> String {
        let digits: Int
        switch self {
        case .stepCount, .heartRate, .workout:
            digits = 0
        case .activeEnergyBurned, .heartRateVariabilitySDNN, .oxygenSaturation:
            digits = 1
        }
        return value.formatted(.number.precision(.fractionLength(digits)))
    }

    func formatWithUnit(_ value: Double) -> String {
        "\(format(value)) \(chartUnit)"
    }
}
