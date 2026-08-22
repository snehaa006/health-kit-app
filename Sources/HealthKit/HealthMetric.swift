import Foundation
import HealthKit

/// The health data types this app syncs.
///
/// Every case owns its HealthKit sample type, the unit we read it in, and the
/// unit string that lands in Supabase — so the dashboard never has to guess what
/// a number means.
///
/// Blood pressure is deliberately absent: Apple Watch does not measure it, so it
/// only appears in HealthKit when manually logged or written by a paired cuff.
enum HealthMetric: String, CaseIterable, Identifiable, Sendable {
    case heartRate
    case stepCount
    case activeEnergyBurned
    case oxygenSaturation
    case heartRateVariabilitySDNN
    case workout

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .heartRate:                return "Heart Rate"
        case .stepCount:                return "Steps"
        case .activeEnergyBurned:       return "Active Energy"
        case .oxygenSaturation:         return "Blood Oxygen"
        case .heartRateVariabilitySDNN: return "HRV (SDNN)"
        case .workout:                  return "Workouts"
        }
    }

    var symbolName: String {
        switch self {
        case .heartRate:                return "heart.fill"
        case .stepCount:                return "figure.walk"
        case .activeEnergyBurned:       return "flame.fill"
        case .oxygenSaturation:         return "lungs.fill"
        case .heartRateVariabilitySDNN: return "waveform.path.ecg"
        case .workout:                  return "figure.run.square.stack"
        }
    }

    /// The HealthKit type to query and to request read access for.
    var sampleType: HKSampleType {
        switch self {
        case .heartRate:                return HKQuantityType(.heartRate)
        case .stepCount:                return HKQuantityType(.stepCount)
        case .activeEnergyBurned:       return HKQuantityType(.activeEnergyBurned)
        case .oxygenSaturation:         return HKQuantityType(.oxygenSaturation)
        case .heartRateVariabilitySDNN: return HKQuantityType(.heartRateVariabilitySDNN)
        case .workout:                  return HKObjectType.workoutType()
        }
    }

    /// Unit used to pull a `Double` out of an `HKQuantity`.
    /// Workouts are not quantity samples, so they have none.
    var readUnit: HKUnit? {
        switch self {
        case .heartRate:                return HKUnit.count().unitDivided(by: .minute())
        case .stepCount:                return .count()
        case .activeEnergyBurned:       return .kilocalorie()
        case .oxygenSaturation:         return .percent()
        case .heartRateVariabilitySDNN: return .secondUnit(with: .milli)
        case .workout:                  return nil
        }
    }

    /// Value of the `unit` column in Supabase.
    var unitLabel: String {
        switch self {
        case .heartRate:                return "count/min"
        case .stepCount:                return "count"
        case .activeEnergyBurned:       return "kcal"
        case .oxygenSaturation:         return "%"
        case .heartRateVariabilitySDNN: return "ms"
        case .workout:                  return "s"
        }
    }

    /// Converts a raw HealthKit quantity into the number we actually store.
    ///
    /// The only case that needs adjusting is SpO2: HealthKit represents it as a
    /// 0.0–1.0 fraction under `HKUnit.percent()`, so a 97% reading reads back as
    /// 0.97. We scale it to 97 so the dashboard can render it verbatim.
    func normalizedValue(from quantity: HKQuantity) -> Double? {
        guard let readUnit else { return nil }
        let raw = quantity.doubleValue(for: readUnit)
        return self == .oxygenSaturation ? raw * 100 : raw
    }
}
