import Foundation
import Observation
import Supabase

/// Wraps the Supabase client and owns the signed-in session.
///
/// The SDK persists sessions in the Keychain and refreshes expired access tokens
/// on its own, so signing in once on the device is genuinely once -- `restore()`
/// picks the session back up on every subsequent launch, including the launches
/// HealthKit triggers in the background.
@MainActor
@Observable
final class SupabaseService {

    static let shared = SupabaseService()

    let client: SupabaseClient

    private(set) var userID: UUID?
    private(set) var email: String?
    private(set) var isRestoring = true
    private(set) var lastError: String?

    var isSignedIn: Bool { userID != nil }

    private init() {
        client = SupabaseClient(
            supabaseURL: SupabaseConfig.url,
            supabaseKey: SupabaseConfig.anonKey
        )
    }

    // MARK: - Session

    /// Reads any Keychain-persisted session. A throw here means "nobody is signed
    /// in", which is an ordinary state on first launch, not a failure worth
    /// surfacing.
    func restore() async {
        isRestoring = true
        defer { isRestoring = false }
        do {
            let session = try await client.auth.session
            apply(session)
        } catch {
            userID = nil
            email = nil
        }
    }

    func signIn(email address: String, password: String) async {
        lastError = nil
        do {
            let session = try await client.auth.signIn(
                email: address.trimmingCharacters(in: .whitespacesAndNewlines),
                password: password
            )
            apply(session)
        } catch {
            lastError = Self.readable(error)
        }
    }

    func signOut() async {
        do {
            try await client.auth.signOut()
        } catch {
            // Local state is cleared regardless: a failed network round-trip
            // should not leave the UI claiming the user is still signed in.
            lastError = Self.readable(error)
        }
        userID = nil
        email = nil
    }

    private func apply(_ session: Session) {
        userID = session.user.id
        email = session.user.email
        lastError = nil
    }

    private static func readable(_ error: Error) -> String {
        let message = error.localizedDescription
        if message.localizedCaseInsensitiveContains("email not confirmed") {
            return "That user exists but its email is unconfirmed. In the Supabase dashboard, delete the user and re-add it with \"Auto Confirm User\" ticked."
        }
        if message.localizedCaseInsensitiveContains("invalid login credentials") {
            return "Invalid email or password."
        }
        return message
    }

    // MARK: - Writes

    /// Upserts rows against the unique index on (patient_id, healthkit_uuid), so a
    /// sample that arrives twice updates in place instead of duplicating.
    ///
    /// `nonisolated` on purpose: `execute()` hands back a `PostgrestResponse`,
    /// which is not `Sendable`. Isolated to the main actor, that return value
    /// would have to cross an isolation boundary and the compiler rejects it
    /// under Swift 6. Running the whole call nonisolated keeps the response from
    /// ever crossing -- and keeps network I/O off the main actor, which is where
    /// it belongs anyway. `client` is a `let` of a `Sendable` type, so reading it
    /// from here is legal.
    nonisolated func upsert(_ rows: [HealthSampleRow]) async throws {
        guard !rows.isEmpty else { return }
        for chunk in rows.chunked(into: SupabaseConfig.uploadChunkSize) {
            try await client
                .from(SupabaseConfig.table)
                .upsert(chunk, onConflict: SupabaseConfig.conflictTarget)
                .execute()
        }
    }

    // MARK: - Reads

    /// Pulls every metric for the dashboard in a single round trip.
    ///
    /// Deliberately *not* one request per type: six sequential round trips is
    /// six times the latency for the same bytes, and PostgREST is happy to
    /// return the lot in one response for the charts to group locally. The
    /// `(patient_id, type, start_date desc)` index in schema.sql covers this.
    ///
    /// `nonisolated` for the same reason as the writes -- `PostgrestResponse` is
    /// not `Sendable`, so the call is kept off the main actor entirely and only
    /// the decoded (and `Sendable`) rows come back.
    nonisolated func fetchSamples(
        since: Date,
        patientID: UUID,
        limit: Int = 20_000
    ) async throws -> [HealthSampleReading] {
        try await client
            .from(SupabaseConfig.table)
            .select("id,type,value,unit,start_date,source")
            .eq("patient_id", value: patientID)
            .gte("start_date", value: HealthSampleRow.timestamp(since))
            .order("start_date", ascending: true)
            .limit(limit)
            .execute()
            .value
    }

    /// Mirrors deletions the user made in the Health app.
    nonisolated func delete(healthKitUUIDs uuids: [UUID], patientID: UUID) async throws {
        guard !uuids.isEmpty else { return }
        for chunk in uuids.chunked(into: SupabaseConfig.uploadChunkSize) {
            try await client
                .from(SupabaseConfig.table)
                .delete()
                .eq("patient_id", value: patientID)
                .in("healthkit_uuid", values: chunk.map(\.uuidString))
                .execute()
        }
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}
