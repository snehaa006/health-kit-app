# HealthKitSync

An iOS companion app that reads Apple Health data — including everything an
Apple Watch records — and syncs it to Supabase, where a patient/doctor dashboard
can read it under Row Level Security.

Verified end to end on a physical iPhone 15 paired with an Apple Watch:
**1,012 rows synced**, incremental re-syncs confirmed working.

---

## How Apple Watch data actually arrives

```
Apple Watch  ──sync──▶  iPhone's HealthKit store  ──read──▶  this app  ──▶  Supabase
```

The app never talks to the Watch directly, and there is no watchOS target. The
Watch syncs its samples into the paired iPhone's HealthKit store, and the app
reads that store. Provenance survives the trip in the `source` /
`source_bundle_id` columns, so Watch samples stay distinguishable from
phone-recorded ones.

**This means the app must run on the physical iPhone paired to the Watch.** A
simulator has an empty HealthKit store and no pairing, so it can never show real
Watch data.

## Metrics

| Metric | Unit stored | Chart | Typical source |
|---|---|---|---|
| Heart Rate | `count/min` | line | Apple Watch |
| Steps | `count` | daily bars | iPhone + Watch |
| Active Energy | `kcal` | daily bars | Apple Watch |
| Blood Oxygen | `%` | line | Apple Watch |
| HRV (SDNN) | `ms` | line | Apple Watch |
| Workouts | `s` (charted as min) | daily bars | Apple Watch |

Blood pressure is deliberately absent — the Watch does not measure it.

## Architecture

| Layer | Files | Role |
|---|---|---|
| Model | `HealthKit/HealthMetric.swift` | Each metric owns its `HKSampleType`, read unit, and stored unit label |
| Auth | `HealthKit/HealthKitManager.swift` | One `HKHealthStore`, read-only authorization, plus a data-visibility probe |
| Sync | `HealthKit/HealthSyncEngine.swift`, `SyncAnchorStore.swift` | `HKAnchoredObjectQuery` paging, one persisted anchor per metric |
| Upload | `Supabase/HealthSampleRow.swift`, `SupabaseService.swift`, `SupabaseConfig.swift` | Keychain-backed session, chunked upsert, deletion mirroring |
| Read | `Supabase/HealthSampleReading.swift` | Decodable mirror of the write model, used by the dashboard |
| UI | `Views/` | Sign-in, sync controls, and the Swift Charts dashboard |
| DB | `supabase/schema.sql` | `public.health_samples` + RLS policies |

### Two design decisions worth knowing

**Upload before advancing the anchor.** The anchor records a position in
HealthKit's insert order. Advancing it before a successful upload would mark
samples as delivered that never reached Supabase, and HealthKit never replays
them — the data would be gone for good.

**Deduplicate on `healthkit_uuid`, not `(type, start_date, source)`.** An iPhone
and a Watch can each record a step sample at the same instant. HealthKit models
those as two genuine samples, not a duplicate, and only the UUID tells them
apart.

## Dashboard

Charts read back from **Supabase**, not from HealthKit. That makes them a check
on the sync as well as a view of the data: if a chart looks right, the round trip
worked.

- One request fetches all six metrics, riding the
  `(patient_id, type, start_date desc)` index.
- Cumulative metrics (steps, energy, workouts) are summed into daily bars —
  HealthKit records steps in bursts of seconds, so raw samples would plot noise.
- Rate metrics (heart rate, HRV, SpO₂) are drawn as readings, with the y-axis
  free to not start at zero.
- Above 600 readings, points are averaged into hourly buckets to stay legible.
- Metrics with nothing in them still render a "No data yet" row, so an empty
  metric never looks like a missing one.

## Setup

### Database

Run `supabase/schema.sql` in the Supabase SQL Editor. It is idempotent. The
signed-in user must have a matching row in `public.patients` — `patient_id`
references it, so a user without one fails on the foreign key.

### Building

Requires [XcodeGen](https://github.com/yonaskolb/XcodeGen); `project.yml` is the
source of truth and `.xcodeproj` is generated.

```sh
brew install xcodegen
xcodegen generate
open HealthKitSync.xcodeproj
```

Select your physical iPhone as the destination and run.

### Signing

`DEVELOPMENT_TEAM` lives in `project.yml` on purpose. Xcode writes it into
`project.pbxproj`, which XcodeGen regenerates — so setting it only in Xcode means
losing it on the next regenerate.

A **free Personal Team signs both HealthKit entitlements**, background delivery
included, so no paid membership is needed. Free provisioning profiles expire
after 7 days; rebuild to continue.

### On the device

1. Settings → Privacy & Security → **Developer Mode** → on, then reboot.
2. Build and run, then trust the developer under Settings → General → VPN &
   Device Management.
3. Sign in, grant Health access — **turn on every type**, they default to off.
4. Tap **Sync Now**.

## About the committed anon key

`SupabaseConfig.anonKey` is committed intentionally. The anon key is designed to
ship inside client binaries and carries only the `anon` Postgres role; every
policy on `health_samples` is scoped `to authenticated` with
`patient_id = auth.uid()`. Row Level Security, not the secrecy of that string, is
what protects the data.

The `service_role` key is the opposite in every respect and must never appear
there.

## Status

**Working**

- HealthKit read authorization (read-only; no write permission is requested)
- Anchored incremental sync, verified: a second run reports "Already up to date"
  rather than re-uploading
- Apple Watch data flowing — heart rate, active energy, HRV, steps
- Deletion mirroring from the Health app
- Swift Charts dashboard reading back from Supabase

**Not built yet**

- **Background delivery** (`HKObserverQuery` + `enableBackgroundDelivery`).
  The entitlement is declared and verified as signable; the code is not written,
  so syncing is manual for now.

**Notes**

- Blood oxygen may never produce data: it is disabled in hardware on Series 9/10
  units sold in the US after the 2024 import ruling.
- HRV is recorded sparsely by the Watch, so a low count is normal rather than a
  sync failure.
