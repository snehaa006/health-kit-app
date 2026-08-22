import SwiftUI

/// Charting details for each metric.
///
/// Kept as an extension in the view layer rather than folded into
/// `HealthMetric` itself: the sync engine runs in the background and has no
/// business importing SwiftUI, so the domain type stays free of view concerns.
extension HealthMetric {

    /// How a metric reads best over time.
    enum ChartKind: Equatable {
        /// Summed into one bar per day. Counts, distances and durations are
        /// meaningless as individual samples -- HealthKit records steps in bursts
        /// of a few seconds, so plotting raw samples draws noise rather than a
        /// day's activity.
        case dailyTotal
        /// Drawn as individual readings. Rates, ratios and measurements would be
        /// destroyed by summing: a day of heart rate does not add up to anything
        /// a person would recognise, and neither does a day of body weight.
        case reading
    }

    var chartKind: ChartKind {
        switch self {
        case .stepCount, .distanceWalkingRunning, .distanceCycling, .flightsClimbed,
             .activeEnergyBurned, .basalEnergyBurned, .appleExerciseTime,
             .appleStandTime, .appleStandHour, .timeInDaylight, .workout,
             .sleepAnalysis, .mindfulSession,
             .highHeartRateEvent, .lowHeartRateEvent, .irregularHeartRhythmEvent:
            return .dailyTotal
        default:
            return .reading
        }
    }

    var tint: Color {
        switch self {
        case .activeEnergyBurned, .basalEnergyBurned: return .orange
        case .heartRateVariabilitySDNN:               return .purple
        case .oxygenSaturation:                       return .blue
        case .workout:                                return .mint
        case .timeInDaylight:                         return .yellow
        default:
            switch group {
            case .heart:       return .pink
            case .respiratory: return .cyan
            case .activity:    return .green
            case .sleep:       return .indigo
            case .body:        return .brown
            case .mobility:    return .teal
            case .hearing:     return .yellow
            }
        }
    }

    /// The unit a chart is labelled in, which is not always the unit stored.
    ///
    /// Durations are stored in seconds because that is what the interval gives
    /// us, and distances in metres because that is what HealthKit reports -- but
    /// a bar 28,800 tall says far less than one labelled 8 hr.
    var chartUnit: String {
        switch self {
        case .sleepAnalysis:                          return "hr"
        case .workout, .mindfulSession:               return "min"
        case .distanceWalkingRunning, .distanceCycling: return "km"
        default:                                      return unitLabel
        }
    }

    func chartValue(_ stored: Double) -> Double {
        switch self {
        case .sleepAnalysis:                            return stored / 3600
        case .workout, .mindfulSession:                 return stored / 60
        case .distanceWalkingRunning, .distanceCycling: return stored / 1000
        default:                                        return stored
        }
    }

    /// Decimal places that suit the metric: a fractional step is nonsense, while
    /// a whole-number blood oxygen throws away the only variation it has.
    func format(_ value: Double) -> String {
        let digits: Int
        switch self {
        case .stepCount, .flightsClimbed, .heartRate, .restingHeartRate,
             .walkingHeartRateAverage, .heartRateRecoveryOneMinute, .respiratoryRate,
             .activeEnergyBurned, .basalEnergyBurned, .appleExerciseTime,
             .appleStandTime, .appleStandHour, .timeInDaylight, .workout,
             .mindfulSession, .environmentalAudioExposure, .headphoneAudioExposure,
             .highHeartRateEvent, .lowHeartRateEvent, .irregularHeartRhythmEvent:
            digits = 0
        case .walkingStepLength, .walkingSpeed, .stairAscentSpeed, .stairDescentSpeed,
             .height, .physicalEffort:
            digits = 2
        default:
            digits = 1
        }
        return value.formatted(.number.precision(.fractionLength(digits)))
    }

    func formatWithUnit(_ value: Double) -> String {
        "\(format(value)) \(chartUnit)"
    }
}
