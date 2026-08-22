import Foundation
import HealthKit

/// Extra detail for workouts, which have no single scalar value.
/// Lands in the `metadata` jsonb column.
struct WorkoutMetadata: Encodable, Sendable, Equatable {
    let activityID: UInt
    let activityName: String
    let totalEnergyKcal: Double?
    let totalDistanceMeters: Double?

    enum CodingKeys: String, CodingKey {
        case activityID = "activity_id"
        case activityName = "activity_name"
        case totalEnergyKcal = "total_energy_kcal"
        case totalDistanceMeters = "total_distance_m"
    }
}

/// One row of `public.health_samples`.
///
/// Deliberately a plain value type: it is built on a background queue inside the
/// HealthKit query handler, then handed across an actor boundary. `HKSample` is
/// a non-`Sendable` class, so converting to this struct before crossing is what
/// keeps the sync engine clean under Swift 6 strict concurrency.
struct HealthSampleRow: Encodable, Sendable, Equatable {
    let patientID: UUID
    let type: String
    let value: Double?
    let unit: String
    let startDate: String
    let endDate: String
    let source: String?
    let sourceBundleID: String?
    let metadata: WorkoutMetadata?
    let healthKitUUID: UUID

    enum CodingKeys: String, CodingKey {
        case patientID = "patient_id"
        case type
        case value
        case unit
        case startDate = "start_date"
        case endDate = "end_date"
        case source
        case sourceBundleID = "source_bundle_id"
        case metadata
        case healthKitUUID = "healthkit_uuid"
    }
}

// MARK: - Mapping from HealthKit

extension HealthSampleRow {

    /// Postgres `timestamptz` parses RFC 3339 directly. Fractional seconds are
    /// kept because high-frequency heart-rate samples can land inside the same
    /// second, and the pair (start_date, type) is how the dashboard orders them.
    static func timestamp(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    /// Converts a batch of HealthKit samples into rows.
    ///
    /// Returns only samples that could be represented; anything unexpected for
    /// the metric is skipped rather than uploaded as a null.
    static func rows(
        from samples: [HKSample],
        metric: HealthMetric,
        patientID: UUID
    ) -> [HealthSampleRow] {
        samples.compactMap { sample in
            let source = sample.sourceRevision.source

            if metric == .workout {
                guard let workout = sample as? HKWorkout else { return nil }
                return HealthSampleRow(
                    patientID: patientID,
                    type: metric.rawValue,
                    value: workout.duration,
                    unit: metric.unitLabel,
                    startDate: timestamp(workout.startDate),
                    endDate: timestamp(workout.endDate),
                    source: source.name,
                    sourceBundleID: source.bundleIdentifier,
                    metadata: WorkoutMetadata(
                        activityID: workout.workoutActivityType.rawValue,
                        activityName: workout.workoutActivityType.displayName,
                        // `totalEnergyBurned` / `totalDistance` are deprecated as of
                        // iOS 18; `statistics(for:)` is the supported replacement.
                        totalEnergyKcal: workout
                            .statistics(for: HKQuantityType(.activeEnergyBurned))?
                            .sumQuantity()?
                            .doubleValue(for: .kilocalorie()),
                        totalDistanceMeters: workout.totalDistanceMeters
                    ),
                    healthKitUUID: workout.uuid
                )
            }

            guard
                let quantitySample = sample as? HKQuantitySample,
                let value = metric.normalizedValue(from: quantitySample.quantity)
            else { return nil }

            return HealthSampleRow(
                patientID: patientID,
                type: metric.rawValue,
                value: value,
                unit: metric.unitLabel,
                startDate: timestamp(quantitySample.startDate),
                endDate: timestamp(quantitySample.endDate),
                source: source.name,
                sourceBundleID: source.bundleIdentifier,
                metadata: nil,
                healthKitUUID: quantitySample.uuid
            )
        }
    }
}

// MARK: - Workout distance

extension HKWorkout {
    /// Distance is recorded under a different quantity type per activity, so a
    /// single lookup against `distanceWalkingRunning` silently returns nil for a
    /// bike ride or a swim. Checks each type an Apple Watch actually writes and
    /// takes the first that carries a total.
    var totalDistanceMeters: Double? {
        let distanceTypes: [HKQuantityTypeIdentifier] = [
            .distanceWalkingRunning,
            .distanceCycling,
            .distanceSwimming,
            .distanceWheelchair,
            .distanceDownhillSnowSports,
        ]
        for identifier in distanceTypes {
            if let meters = statistics(for: HKQuantityType(identifier))?
                .sumQuantity()?
                .doubleValue(for: .meter()) {
                return meters
            }
        }
        return nil
    }
}

// MARK: - Activity names

extension HKWorkoutActivityType {
    /// Covers what an Apple Watch realistically records. Anything else keeps its
    /// numeric identity so the dashboard can still group it.
    var displayName: String {
        switch self {
        case .walking:                  return "Walking"
        case .running:                  return "Running"
        case .cycling:                  return "Cycling"
        case .swimming:                 return "Swimming"
        case .hiking:                   return "Hiking"
        case .yoga:                     return "Yoga"
        case .functionalStrengthTraining: return "Functional Strength"
        case .traditionalStrengthTraining: return "Strength Training"
        case .highIntensityIntervalTraining: return "HIIT"
        case .coreTraining:             return "Core Training"
        case .elliptical:               return "Elliptical"
        case .rowing:                   return "Rowing"
        case .stairClimbing:            return "Stair Climbing"
        case .dance:                    return "Dance"
        case .pilates:                  return "Pilates"
        case .mindAndBody:              return "Mind and Body"
        case .cooldown:                 return "Cooldown"
        case .preparationAndRecovery:   return "Preparation and Recovery"
        case .flexibility:              return "Flexibility"
        case .mixedCardio:              return "Mixed Cardio"
        case .other:                    return "Other"
        default:                        return "Activity \(rawValue)"
        }
    }
}
