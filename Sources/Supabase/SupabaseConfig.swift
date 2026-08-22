import Foundation

enum SupabaseConfig {
    static let url = URL(string: "https://pghvmhakfwtxkwvlxokc.supabase.co")!

    /// The anon (publishable) key. Committing this is intentional and safe: it is
    /// designed to ship inside client binaries, carries only the `anon` Postgres
    /// role, and every policy on `health_samples` is scoped `to authenticated`
    /// with `user_id = auth.uid()`. Row Level Security -- not the secrecy of this
    /// string -- is what protects the data.
    ///
    /// The `service_role` key is the opposite in every respect and must never
    /// appear in this file.
    static let anonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InBnaHZtaGFrZnd0eGt3dmx4b2tjIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODUyMjMwNTMsImV4cCI6MjEwMDc5OTA1M30.i4F-A_vA9JOqZS-TYlSPu09pJEmCLM3kr76Q1_1H4SM"

    /// Table that receives every sample.
    static let table = "health_samples"

    /// Matches the unique index `health_samples_user_hk_uuid_key`. PostgREST needs
    /// the exact column list to turn an insert into an upsert.
    static let conflictTarget = "user_id,healthkit_uuid"

    /// How far back to reach on the very first sync. Without a bound, the initial
    /// anchored query would walk years of heart-rate samples -- easily hundreds of
    /// thousands of rows -- on a phone, over cellular.
    static let initialHistoryWindow: TimeInterval = 30 * 24 * 60 * 60

    /// Samples pulled out of HealthKit per anchored-query page.
    static let fetchPageSize = 5_000

    /// Rows per PostgREST request. Keeps individual uploads small enough to retry
    /// cheaply on a flaky connection.
    static let uploadChunkSize = 500
}
