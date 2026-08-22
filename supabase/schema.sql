-- HealthKit -> Supabase sync schema
-- Run this whole file once in the Supabase SQL Editor.

create table if not exists public.health_samples (
    id                uuid        primary key default gen_random_uuid(),
    user_id           uuid        not null default auth.uid()
                                  references auth.users (id) on delete cascade,

    -- One of: heartRate | stepCount | activeEnergyBurned
    --       | oxygenSaturation | heartRateVariabilitySDNN | workout
    type              text        not null,
    value             double precision,
    unit              text        not null,

    start_date        timestamptz not null,
    end_date          timestamptz not null,

    -- HKSource.name, e.g. "Sneha's Apple Watch"
    source            text,
    -- HKSource.bundleIdentifier: the reliable way to tell Apple-generated
    -- samples from third-party health apps writing into the same store.
    source_bundle_id  text,

    -- Workout details (activity type, distance, energy) and anything else
    -- that doesn't fit a single scalar.
    metadata          jsonb,

    -- HKSample.uuid. This is the deduplication key -- see the unique index.
    healthkit_uuid    uuid        not null,

    created_at        timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Deduplication
-- ---------------------------------------------------------------------------
-- Every HKSample carries a stable `uuid` that is unique within the device's
-- HealthKit store and survives restores from backup. That is a far safer
-- identity than (type, start_date, source): two genuinely distinct samples can
-- legitimately share those three values -- for example step counts recorded by
-- the iPhone and the Watch at the same instant, which HealthKit models as two
-- real samples with different source priorities, not as a duplicate.
--
-- Scoped by user_id so the constraint still holds if you add users later.
create unique index if not exists health_samples_user_hk_uuid_key
    on public.health_samples (user_id, healthkit_uuid);

-- The dashboard's main access pattern: "latest N of type X" and
-- "everything of type X between two dates".
create index if not exists health_samples_user_type_start_idx
    on public.health_samples (user_id, type, start_date desc);

-- ---------------------------------------------------------------------------
-- Row Level Security
-- ---------------------------------------------------------------------------
alter table public.health_samples enable row level security;

-- `(select auth.uid())` rather than a bare `auth.uid()` is deliberate: the
-- subquery form is evaluated once per statement as an InitPlan instead of once
-- per row. On a table that accumulates a heart-rate sample every few seconds
-- that difference is the whole query plan.
--
-- `to authenticated` keeps the anon role -- the one whose key ships inside the
-- app binary -- from matching any policy at all.

create policy "health_samples: select own"
    on public.health_samples for select
    to authenticated
    using (user_id = (select auth.uid()));

create policy "health_samples: insert own"
    on public.health_samples for insert
    to authenticated
    with check (user_id = (select auth.uid()));

-- Needed because the sync upserts: an edited sample re-arrives from the
-- anchored query and lands on the unique index as a conflict.
create policy "health_samples: update own"
    on public.health_samples for update
    to authenticated
    using (user_id = (select auth.uid()))
    with check (user_id = (select auth.uid()));

-- Needed because HKAnchoredObjectQuery reports deletions: when you remove a bad
-- reading in the Health app, the next sync deletes the corresponding row here.
create policy "health_samples: delete own"
    on public.health_samples for delete
    to authenticated
    using (user_id = (select auth.uid()));
