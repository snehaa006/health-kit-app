import Foundation

/// One row read back out of `public.health_samples`.
///
/// The write path has its own type, `HealthSampleRow`, which is `Encodable`
/// only: it exists to turn an `HKSample` into JSON and never needs to survive a
/// round trip. This is the mirror image -- what the dashboard reads back. Keeping
/// the two apart means the upload payload stays minimal while the read model can
/// carry whatever the charts need, and neither drags the other's requirements
/// along.
struct HealthSampleReading: Decodable, Sendable, Identifiable, Equatable {

    /// The slice of `metadata` the charts actually need.
    ///
    /// Sleep is the reason this exists: HealthKit nests the asleep stages inside
    /// an enclosing `inBed` sample, so a nightly total that ignores the stage
    /// counts most of the night twice.
    struct Metadata: Decodable, Sendable, Equatable {
        let categoryValue: Int?
        let categoryName: String?
        let activityName: String?

        enum CodingKeys: String, CodingKey {
            case categoryValue = "category_value"
            case categoryName = "category_name"
            case activityName = "activity_name"
        }
    }

    let id: UUID
    let type: String
    let value: Double?
    let unit: String
    let startDate: Date
    let source: String?
    let metadata: Metadata?

    enum CodingKeys: String, CodingKey {
        case id, type, value, unit, source, metadata
        case startDate = "start_date"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id        = try container.decode(UUID.self, forKey: .id)
        type      = try container.decode(String.self, forKey: .type)
        value     = try container.decodeIfPresent(Double.self, forKey: .value)
        unit      = try container.decode(String.self, forKey: .unit)
        source    = try container.decodeIfPresent(String.self, forKey: .source)
        metadata  = try container.decodeIfPresent(Metadata.self, forKey: .metadata)

        // Parsed by hand rather than through a `dateDecodingStrategy`, because
        // Postgres renders `timestamptz` with a variable number of fractional
        // digits -- a heart-rate sample lands on `.375`, but one that happens to
        // fall on a whole second comes back with no fraction at all. A single
        // fixed strategy throws on whichever shape it wasn't configured for, and
        // that failure would take down the entire page rather than one row.
        let raw = try container.decode(String.self, forKey: .startDate)
        guard let parsed = Self.parseTimestamp(raw) else {
            throw DecodingError.dataCorruptedError(
                forKey: .startDate,
                in: container,
                debugDescription: "Unrecognised timestamp: \(raw)"
            )
        }
        startDate = parsed
    }

    /// `ISO8601DateFormatter` is documented as thread-safe, and both instances
    /// are immutable after setup, so sharing them avoids rebuilding a formatter
    /// per row -- which matters when a month of heart rate is a few thousand rows.
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let whole: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parseTimestamp(_ raw: String) -> Date? {
        fractional.date(from: raw) ?? whole.date(from: raw)
    }
}
