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

/// Extra detail for category samples, which carry a *label* rather than a number.
///
/// This is what makes sleep usable downstream: without the stage, every row in a
/// night looks identical, and summing them would double-count "in bed" against
/// the asleep stages nested inside it.
struct CategoryMetadata: Encodable, Sendable, Equatable {
    let categoryValue: Int
    let categoryName: String

    enum CodingKeys: String, CodingKey {
        case categoryValue = "category_value"
        case categoryName = "category_name"
    }
}

/// Whatever detail a sample carries beyond its scalar value.
///
/// Encoded as a bare single value rather than a tagged wrapper, so the jsonb
/// column holds `{"activity_name": …}` or `{"category_name": …}` directly and
/// stays queryable from SQL without unwrapping a discriminator first.
enum SampleMetadata: Encodable, Sendable, Equatable {
    case workout(WorkoutMetadata)
    case category(CategoryMetadata)

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .workout(let value):  try container.encode(value)
        case .category(let value): try container.encode(value)
        }
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
    let metadata: SampleMetadata?
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

            switch metric.kind {

            case .workout:
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
                    metadata: .workout(
                        WorkoutMetadata(
                            activityID: workout.workoutActivityType.rawValue,
                            activityName: workout.workoutActivityType.displayName,
                            // `totalEnergyBurned` / `totalDistance` are deprecated as of
                            // iOS 18; `statistics(for:)` is the supported replacement.
                            totalEnergyKcal: workout
                                .statistics(for: HKQuantityType(.activeEnergyBurned))?
                                .sumQuantity()?
                                .doubleValue(for: .kilocalorie()),
                            totalDistanceMeters: workout.totalDistanceMeters
                        )
                    ),
                    healthKitUUID: workout.uuid
                )

            case .category:
                guard let categorySample = sample as? HKCategorySample else { return nil }
                return HealthSampleRow(
                    patientID: patientID,
                    type: metric.rawValue,
                    value: metric.categoryValue(for: categorySample),
                    unit: metric.unitLabel,
                    startDate: timestamp(categorySample.startDate),
                    endDate: timestamp(categorySample.endDate),
                    source: source.name,
                    sourceBundleID: source.bundleIdentifier,
                    metadata: .category(
                        CategoryMetadata(
                            categoryValue: categorySample.value,
                            categoryName: metric.categoryName(for: categorySample.value)
                        )
                    ),
                    healthKitUUID: categorySample.uuid
                )

            case .quantity:
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
}

// MARK: - Category samples

extension HealthMetric {

    /// Sleep stages that mean *actually asleep*.
    ///
    /// HealthKit nests the asleep stages inside an enclosing `inBed` sample, so
    /// summing every sleep row for a night roughly doubles the total. Anything
    /// totalling sleep has to filter to these first.
    static let asleepCategoryValues: Set<Int> = [
        HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
        HKCategoryValueSleepAnalysis.asleepCore.rawValue,
        HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
        HKCategoryValueSleepAnalysis.asleepREM.rawValue,
    ]

    /// The number stored for a category sample.
    ///
    /// Intervals keep their duration; events keep a count of 1. A high-heart-rate
    /// notification is instantaneous, so storing its duration would record zero
    /// and chart as though it never happened.
    func categoryValue(for sample: HKCategorySample) -> Double {
        switch self {
        case .sleepAnalysis, .mindfulSession:
            return sample.endDate.timeIntervalSince(sample.startDate)
        default:
            return 1
        }
    }

    func categoryName(for value: Int) -> String {
        switch self {
        case .sleepAnalysis:
            switch HKCategoryValueSleepAnalysis(rawValue: value) {
            case .inBed:              return "In Bed"
            case .asleepUnspecified:  return "Asleep"
            case .asleepCore:         return "Core"
            case .asleepDeep:         return "Deep"
            case .asleepREM:          return "REM"
            case .awake:              return "Awake"
            default:                  return "Stage \(value)"
            }
        case .appleStandHour:
            return value == HKCategoryValueAppleStandHour.stood.rawValue ? "Stood" : "Idle"
        case .mindfulSession:
            return "Mindful Session"
        case .highHeartRateEvent:        return "High Heart Rate"
        case .lowHeartRateEvent:         return "Low Heart Rate"
        case .irregularHeartRhythmEvent: return "Irregular Rhythm"
        default:                         return "Event"
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
