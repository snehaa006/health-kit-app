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

**37 metrics across 7 groups.** Three different shapes of HealthKit sample, and
the difference matters at every layer:

| Shape | Examples | Carries |
|---|---|---|
| **Quantity** | heart rate, steps, weight, walking speed | a number + unit |
| **Category** | sleep, mindful sessions, stand hours, heart events | an interval + a *label*, no number |
| **Workout** | any recorded workout | an interval + totals |

| Group | Metrics |
|---|---|
| **Heart** | Heart rate, resting HR, walking HR, HRV, HR recovery, VO₂ max, high/low HR events, irregular rhythm |
| **Respiratory** | Respiratory rate, blood oxygen |
| **Activity** | Steps, walking/running + cycling distance, flights, active + resting energy, exercise/stand time, stand hours, physical effort, daylight, workouts |
| **Sleep & Mind** | Sleep (with stages), mindful minutes |
| **Body** | Weight, height, BMI, body fat, lean mass |
| **Mobility** | Walking speed, step length, asymmetry, double support, stair speeds |
| **Hearing** | Environmental sound, headphone audio |

Blood pressure is deliberately absent — the Watch does not measure it.

### Sleep needs care

Sleep is stored per stage (`inBed`, `asleepCore`, `asleepDeep`, `asleepREM`,
`awake`) in the `metadata` column. HealthKit **nests the asleep stages inside an
enclosing `inBed` interval**, so summing every sleep row for a night roughly
doubles the real total. Anything totalling sleep must filter to the asleep
stages first — the dashboard does.

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

- One request fetches every metric, riding the
  `(patient_id, type, start_date desc)` index.
- Metrics are grouped into sections, and the ones with no data collapse behind a
  disclosure — a flat list of 37 cards is unusable, and most will be empty.
- Cumulative metrics (steps, energy, workouts) are summed into daily bars —
  HealthKit records steps in bursts of seconds, so raw samples would plot noise.
- Rate metrics (heart rate, HRV, SpO₂) are drawn as readings, with the y-axis
  free to not start at zero.
- Above 600 readings, points are averaged into hourly buckets to stay legible.
- Empty metrics stay listed rather than disappearing, so a metric that produced
  nothing never looks like one that failed to sync.

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
- Sleep, category samples, and all 37 metric types
- Deletion mirroring from the Health app
- Swift Charts dashboard reading back from Supabase

- **Automatic background sync** — HealthKit wakes the app when new samples
  arrive, including overnight, with no interaction needed

### How automatic sync works

Two mechanisms have to line up, and neither is sufficient alone:

1. `enableBackgroundDelivery` tells HealthKit it may wake the app. It persists
   across launches and installs.
2. An `HKObserverQuery` per type is what actually receives the wake-up. These do
   **not** persist — they are re-registered on every launch from the app's
   `init`, not from a view, because HealthKit relaunches straight into the
   background where no view is ever created.

The observer's completion handler is called on every path including failure:
skipping it makes iOS back off and eventually stop delivering altogether.

A background launch starts with no session in memory, so the coordinator
restores from the Keychain before syncing — otherwise every background sync
would fail on "sign in first" while a valid session sat unused.

iOS decides the timing and batches to protect battery, so expect roughly hourly
rather than instant.

**Not built yet**

- Nothing blocking; see Notes for hardware limits.

**Notes**

- **Blood oxygen and ECG never produce data on an Apple Watch SE** — it has
  neither sensor. Wrist temperature needs Series 8 or later.
- Adding metric types makes the Health permission sheet reappear, since
  `getRequestStatusForAuthorization` reports `.shouldRequest` again.
- HRV is recorded sparsely by the Watch, so a low count is normal rather than a
  sync failure.
