import Foundation
import HealthKit

/// The health data types this app syncs.
///
/// Every case owns its HealthKit sample type, the unit we read it in, and the
/// unit string that lands in Supabase — so the dashboard never has to guess what
/// a number means.
///
/// `rawValue` is the `type` column in Postgres, so these strings are effectively
/// schema: renaming a case orphans every row already synced under the old name.
///
/// Three shapes of sample live here, and the difference matters at every layer:
/// quantities carry a number, workouts carry an interval plus totals, and
/// category samples carry an interval plus a *label* and no number at all.
enum HealthMetric: String, CaseIterable, Identifiable, Sendable {

    // Heart
    case heartRate
    case restingHeartRate
    case walkingHeartRateAverage
    case heartRateVariabilitySDNN
    case heartRateRecoveryOneMinute
    case vo2Max
    case highHeartRateEvent
    case lowHeartRateEvent
    case irregularHeartRhythmEvent

    // Respiratory
    case respiratoryRate
    case oxygenSaturation

    // Activity
    case stepCount
    case distanceWalkingRunning
    case distanceCycling
    case flightsClimbed
    case activeEnergyBurned
    case basalEnergyBurned
    case appleExerciseTime
    case appleStandTime
    case appleStandHour
    case physicalEffort
    case timeInDaylight
    case workout

    // Sleep & mind
    case sleepAnalysis
    case mindfulSession

    // Body
    case bodyMass
    case height
    case bodyMassIndex
    case bodyFatPercentage
    case leanBodyMass

    // Mobility
    case walkingSpeed
    case walkingStepLength
    case walkingAsymmetryPercentage
    case walkingDoubleSupportPercentage
    case stairAscentSpeed
    case stairDescentSpeed

    // Hearing
    case environmentalAudioExposure
    case headphoneAudioExposure

    var id: String { rawValue }

    // MARK: - Shape

    /// Which HealthKit family a metric belongs to. The mapper branches on this
    /// rather than on `as?` casts scattered through the conversion code.
    enum SampleKind: Sendable {
        case quantity
        case category
        case workout
    }

    var kind: SampleKind {
        switch self {
        case .workout:
            return .workout
        case .sleepAnalysis, .mindfulSession, .appleStandHour,
             .highHeartRateEvent, .lowHeartRateEvent, .irregularHeartRhythmEvent:
            return .category
        default:
            return .quantity
        }
    }

    // MARK: - Grouping

    /// Dashboard sections. Purely presentational, but it lives here so a new
    /// metric can't be added without deciding where it belongs.
    enum Group: String, CaseIterable, Sendable {
        case heart       = "Heart"
        case respiratory = "Respiratory"
        case activity    = "Activity"
        case sleep       = "Sleep & Mind"
        case body        = "Body"
        case mobility    = "Mobility"
        case hearing     = "Hearing"
    }

    var group: Group {
        switch self {
        case .heartRate, .restingHeartRate, .walkingHeartRateAverage,
             .heartRateVariabilitySDNN, .heartRateRecoveryOneMinute, .vo2Max,
             .highHeartRateEvent, .lowHeartRateEvent, .irregularHeartRhythmEvent:
            return .heart
        case .respiratoryRate, .oxygenSaturation:
            return .respiratory
        case .stepCount, .distanceWalkingRunning, .distanceCycling, .flightsClimbed,
             .activeEnergyBurned, .basalEnergyBurned, .appleExerciseTime,
             .appleStandTime, .appleStandHour, .physicalEffort, .timeInDaylight, .workout:
            return .activity
        case .sleepAnalysis, .mindfulSession:
            return .sleep
        case .bodyMass, .height, .bodyMassIndex, .bodyFatPercentage, .leanBodyMass:
            return .body
        case .walkingSpeed, .walkingStepLength, .walkingAsymmetryPercentage,
             .walkingDoubleSupportPercentage, .stairAscentSpeed, .stairDescentSpeed:
            return .mobility
        case .environmentalAudioExposure, .headphoneAudioExposure:
            return .hearing
        }
    }

    // MARK: - Naming

    var displayName: String {
        switch self {
        case .heartRate:                       return "Heart Rate"
        case .restingHeartRate:                return "Resting Heart Rate"
        case .walkingHeartRateAverage:         return "Walking Heart Rate"
        case .heartRateVariabilitySDNN:        return "HRV (SDNN)"
        case .heartRateRecoveryOneMinute:      return "Heart Rate Recovery"
        case .vo2Max:                          return "Cardio Fitness (VO₂ Max)"
        case .highHeartRateEvent:              return "High Heart Rate Events"
        case .lowHeartRateEvent:               return "Low Heart Rate Events"
        case .irregularHeartRhythmEvent:       return "Irregular Rhythm Events"
        case .respiratoryRate:                 return "Respiratory Rate"
        case .oxygenSaturation:                return "Blood Oxygen"
        case .stepCount:                       return "Steps"
        case .distanceWalkingRunning:          return "Walking + Running Distance"
        case .distanceCycling:                 return "Cycling Distance"
        case .flightsClimbed:                  return "Flights Climbed"
        case .activeEnergyBurned:              return "Active Energy"
        case .basalEnergyBurned:               return "Resting Energy"
        case .appleExerciseTime:               return "Exercise Time"
        case .appleStandTime:                  return "Stand Time"
        case .appleStandHour:                  return "Stand Hours"
        case .physicalEffort:                  return "Physical Effort"
        case .timeInDaylight:                  return "Time in Daylight"
        case .workout:                         return "Workouts"
        case .sleepAnalysis:                   return "Sleep"
        case .mindfulSession:                  return "Mindful Minutes"
        case .bodyMass:                        return "Weight"
        case .height:                          return "Height"
        case .bodyMassIndex:                   return "Body Mass Index"
        case .bodyFatPercentage:               return "Body Fat"
        case .leanBodyMass:                    return "Lean Body Mass"
        case .walkingSpeed:                    return "Walking Speed"
        case .walkingStepLength:               return "Step Length"
        case .walkingAsymmetryPercentage:      return "Walking Asymmetry"
        case .walkingDoubleSupportPercentage:  return "Double Support Time"
        case .stairAscentSpeed:                return "Stair Ascent Speed"
        case .stairDescentSpeed:               return "Stair Descent Speed"
        case .environmentalAudioExposure:      return "Environmental Sound"
        case .headphoneAudioExposure:          return "Headphone Audio"
        }
    }

    var symbolName: String {
        switch self {
        case .heartRate:                       return "heart.fill"
        case .restingHeartRate:                return "heart.circle"
        case .walkingHeartRateAverage:         return "heart.text.square"
        case .heartRateVariabilitySDNN:        return "waveform.path.ecg"
        case .heartRateRecoveryOneMinute:      return "arrow.down.heart"
        case .vo2Max:                          return "lungs"
        case .highHeartRateEvent:              return "arrow.up.heart"
        case .lowHeartRateEvent:               return "arrow.down.heart"
        case .irregularHeartRhythmEvent:       return "exclamationmark.triangle"
        case .respiratoryRate:                 return "wind"
        case .oxygenSaturation:                return "lungs.fill"
        case .stepCount:                       return "figure.walk"
        case .distanceWalkingRunning:          return "figure.run"
        case .distanceCycling:                 return "bicycle"
        case .flightsClimbed:                  return "figure.stairs"
        case .activeEnergyBurned:              return "flame.fill"
        case .basalEnergyBurned:               return "flame"
        case .appleExerciseTime:               return "timer"
        case .appleStandTime:                  return "figure.stand"
        case .appleStandHour:                  return "clock.arrow.circlepath"
        case .physicalEffort:                  return "gauge.medium"
        case .timeInDaylight:                  return "sun.max"
        case .workout:                         return "figure.run.square.stack"
        case .sleepAnalysis:                   return "bed.double.fill"
        case .mindfulSession:                  return "brain.head.profile"
        case .bodyMass:                        return "scalemass"
        case .height:                          return "ruler"
        case .bodyMassIndex:                   return "figure"
        case .bodyFatPercentage:               return "percent"
        case .leanBodyMass:                    return "figure.arms.open"
        case .walkingSpeed:                    return "speedometer"
        case .walkingStepLength:               return "ruler.fill"
        case .walkingAsymmetryPercentage:      return "figure.walk.motion"
        case .walkingDoubleSupportPercentage:  return "shoeprints.fill"
        case .stairAscentSpeed:                return "arrow.up.right"
        case .stairDescentSpeed:               return "arrow.down.right"
        case .environmentalAudioExposure:      return "ear"
        case .headphoneAudioExposure:          return "headphones"
        }
    }

    // MARK: - HealthKit types

    /// The HealthKit type to query and to request read access for.
    var sampleType: HKSampleType {
        switch self {
        case .workout:
            return HKObjectType.workoutType()

        case .sleepAnalysis:                   return HKCategoryType(.sleepAnalysis)
        case .mindfulSession:                  return HKCategoryType(.mindfulSession)
        case .appleStandHour:                  return HKCategoryType(.appleStandHour)
        case .highHeartRateEvent:              return HKCategoryType(.highHeartRateEvent)
        case .lowHeartRateEvent:               return HKCategoryType(.lowHeartRateEvent)
        case .irregularHeartRhythmEvent:       return HKCategoryType(.irregularHeartRhythmEvent)

        case .heartRate:                       return HKQuantityType(.heartRate)
        case .restingHeartRate:                return HKQuantityType(.restingHeartRate)
        case .walkingHeartRateAverage:         return HKQuantityType(.walkingHeartRateAverage)
        case .heartRateVariabilitySDNN:        return HKQuantityType(.heartRateVariabilitySDNN)
        case .heartRateRecoveryOneMinute:      return HKQuantityType(.heartRateRecoveryOneMinute)
        case .vo2Max:                          return HKQuantityType(.vo2Max)
        case .respiratoryRate:                 return HKQuantityType(.respiratoryRate)
        case .oxygenSaturation:                return HKQuantityType(.oxygenSaturation)
        case .stepCount:                       return HKQuantityType(.stepCount)
        case .distanceWalkingRunning:          return HKQuantityType(.distanceWalkingRunning)
        case .distanceCycling:                 return HKQuantityType(.distanceCycling)
        case .flightsClimbed:                  return HKQuantityType(.flightsClimbed)
        case .activeEnergyBurned:              return HKQuantityType(.activeEnergyBurned)
        case .basalEnergyBurned:               return HKQuantityType(.basalEnergyBurned)
        case .appleExerciseTime:               return HKQuantityType(.appleExerciseTime)
        case .appleStandTime:                  return HKQuantityType(.appleStandTime)
        case .physicalEffort:                  return HKQuantityType(.physicalEffort)
        case .timeInDaylight:                  return HKQuantityType(.timeInDaylight)
        case .bodyMass:                        return HKQuantityType(.bodyMass)
        case .height:                          return HKQuantityType(.height)
        case .bodyMassIndex:                   return HKQuantityType(.bodyMassIndex)
        case .bodyFatPercentage:               return HKQuantityType(.bodyFatPercentage)
        case .leanBodyMass:                    return HKQuantityType(.leanBodyMass)
        case .walkingSpeed:                    return HKQuantityType(.walkingSpeed)
        case .walkingStepLength:               return HKQuantityType(.walkingStepLength)
        case .walkingAsymmetryPercentage:      return HKQuantityType(.walkingAsymmetryPercentage)
        case .walkingDoubleSupportPercentage:  return HKQuantityType(.walkingDoubleSupportPercentage)
        case .stairAscentSpeed:                return HKQuantityType(.stairAscentSpeed)
        case .stairDescentSpeed:               return HKQuantityType(.stairDescentSpeed)
        case .environmentalAudioExposure:      return HKQuantityType(.environmentalAudioExposure)
        case .headphoneAudioExposure:          return HKQuantityType(.headphoneAudioExposure)
        }
    }

    /// Unit used to pull a `Double` out of an `HKQuantity`.
    /// Workouts and category samples are not quantity samples, so they have none.
    var readUnit: HKUnit? {
        switch self {
        case .workout, .sleepAnalysis, .mindfulSession, .appleStandHour,
             .highHeartRateEvent, .lowHeartRateEvent, .irregularHeartRhythmEvent:
            return nil

        case .heartRate, .restingHeartRate, .walkingHeartRateAverage,
             .heartRateRecoveryOneMinute, .respiratoryRate:
            return HKUnit.count().unitDivided(by: .minute())

        case .heartRateVariabilitySDNN:
            return .secondUnit(with: .milli)

        case .vo2Max:
            // ml/(kg·min) has no constructor; the string initialiser is the
            // documented way to build compound units like this one.
            return HKUnit(from: "ml/kg*min")

        case .oxygenSaturation, .bodyFatPercentage,
             .walkingAsymmetryPercentage, .walkingDoubleSupportPercentage:
            return .percent()

        case .stepCount, .flightsClimbed, .bodyMassIndex:
            return .count()

        case .distanceWalkingRunning, .distanceCycling, .walkingStepLength, .height:
            return .meter()

        case .activeEnergyBurned, .basalEnergyBurned:
            return .kilocalorie()

        case .appleExerciseTime, .appleStandTime, .timeInDaylight:
            return .minute()

        case .physicalEffort:
            return HKUnit(from: "kcal/kg*hr")

        case .bodyMass, .leanBodyMass:
            return .gramUnit(with: .kilo)

        case .walkingSpeed, .stairAscentSpeed, .stairDescentSpeed:
            return HKUnit.meter().unitDivided(by: .second())

        case .environmentalAudioExposure, .headphoneAudioExposure:
            return .decibelAWeightedSoundPressureLevel()
        }
    }

    /// Value of the `unit` column in Supabase.
    var unitLabel: String {
        switch self {
        case .heartRate, .restingHeartRate, .walkingHeartRateAverage,
             .heartRateRecoveryOneMinute, .respiratoryRate:
            return "count/min"
        case .heartRateVariabilitySDNN:                                  return "ms"
        case .vo2Max:                                                    return "ml/kg·min"
        case .oxygenSaturation, .bodyFatPercentage,
             .walkingAsymmetryPercentage, .walkingDoubleSupportPercentage:
            return "%"
        case .stepCount, .flightsClimbed, .bodyMassIndex, .appleStandHour,
             .highHeartRateEvent, .lowHeartRateEvent, .irregularHeartRhythmEvent:
            return "count"
        case .distanceWalkingRunning, .distanceCycling, .walkingStepLength, .height:
            return "m"
        case .activeEnergyBurned, .basalEnergyBurned:                    return "kcal"
        case .appleExerciseTime, .appleStandTime, .timeInDaylight:       return "min"
        case .physicalEffort:                                            return "MET"
        case .bodyMass, .leanBodyMass:                                   return "kg"
        case .walkingSpeed, .stairAscentSpeed, .stairDescentSpeed:       return "m/s"
        case .environmentalAudioExposure, .headphoneAudioExposure:       return "dBASPL"
        // Durations, stored in seconds because that is what the interval gives us.
        case .workout, .sleepAnalysis, .mindfulSession:                  return "s"
        }
    }

    /// Converts a raw HealthKit quantity into the number we actually store.
    ///
    /// HealthKit models every percentage as a 0.0–1.0 fraction, so a 97% blood
    /// oxygen reading comes back as 0.97. Scaling here — rather than at each call
    /// site — means a percentage metric added later cannot forget to do it.
    func normalizedValue(from quantity: HKQuantity) -> Double? {
        guard let readUnit else { return nil }
        let raw = quantity.doubleValue(for: readUnit)
        return readUnit == HKUnit.percent() ? raw * 100 : raw
    }
}
