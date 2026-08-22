-- HealthKit -> Supabase sync target.
--
-- APPLIED to project pghvmhakfwtxkwvlxokc as migration `create_health_samples`.
-- This file is the record of what is deployed; it is idempotent and safe to re-run.
--
-- Follows the conventions already used by lifestyle_logs / weight_logs /
-- meal_tracking: patient_id references public.patients(id), patients own their
-- own rows, and treating doctors get read access via doctor_treats().

create table if not exists public.health_samples (
    id                uuid        primary key default gen_random_uuid(),
    patient_id        uuid        not null default auth.uid()
                                  references public.patients (id) on delete cascade,

    -- heartRate | stepCount | activeEnergyBurned
    -- | oxygenSaturation | heartRateVariabilitySDNN | workout
    type              text        not null,
    value             double precision,
    unit              text        not null,

    start_date        timestamptz not null,
    end_date          timestamptz not null,

    source            text,              -- HKSource.name, e.g. "Sneha's Apple Watch"
    source_bundle_id  text,              -- distinguishes Apple data from third-party writers
    metadata          jsonb,             -- workout activity, distance, energy

    healthkit_uuid    uuid        not null,

    created_at        timestamptz not null default now(),
    updated_at        timestamptz not null default now()
);

comment on table public.health_samples is
    'Samples synced from Apple HealthKit by the iOS companion app. Deduplicated on HKSample.uuid.';

-- Deduplication key. HKSample.uuid is stable per HealthKit store and survives
-- backup restores, unlike a (type, start_date, source) composite: an iPhone and
-- a Watch can each record a step sample at the same instant, which HealthKit
-- models as two real samples resolved by source priority, not a duplicate.
create unique index if not exists health_samples_patient_hk_uuid_key
    on public.health_samples (patient_id, healthkit_uuid);

-- Dashboard access pattern: latest N of a type, or a type across a date range.
create index if not exists health_samples_patient_type_start_idx
    on public.health_samples (patient_id, type, start_date desc);

alter table public.health_samples enable row level security;

-- `(select auth.uid())` rather than a bare `auth.uid()` is a deliberate
-- deviation from the sibling tables: the subquery form is evaluated once per
-- statement as an InitPlan instead of once per row. This table takes a
-- heart-rate sample every few seconds and will outgrow every other table here
-- by orders of magnitude, so the difference shows up in the query plan.

drop policy if exists "patients read their own health samples" on public.health_samples;
create policy "patients read their own health samples"
    on public.health_samples for select
    to authenticated
    using (patient_id = (select auth.uid()));

drop policy if exists "patients record their own health samples" on public.health_samples;
create policy "patients record their own health samples"
    on public.health_samples for insert
    to authenticated
    with check (patient_id = (select auth.uid()));

-- Required because the sync upserts: a re-delivered sample collides with the
-- unique index and falls through to an UPDATE.
drop policy if exists "patients update their own health samples" on public.health_samples;
create policy "patients update their own health samples"
    on public.health_samples for update
    to authenticated
    using (patient_id = (select auth.uid()))
    with check (patient_id = (select auth.uid()));

-- Required because HKAnchoredObjectQuery reports deletions: removing a bad
-- reading in the Health app must propagate here.
drop policy if exists "patients delete their own health samples" on public.health_samples;
create policy "patients delete their own health samples"
    on public.health_samples for delete
    to authenticated
    using (patient_id = (select auth.uid()));

-- Mirrors "doctors read weight logs for their patients" so the doctor-facing
-- dashboard can see synced data at all.
drop policy if exists "doctors read health samples for their patients" on public.health_samples;
create policy "doctors read health samples for their patients"
    on public.health_samples for select
    to authenticated
    using (doctor_treats(patient_id));

create or replace function public.health_samples_touch_updated_at()
returns trigger
language plpgsql
set search_path to 'public'
as $$
begin
    new.updated_at = now();
    return new;
end;
$$;

drop trigger if exists health_samples_set_updated_at on public.health_samples;
create trigger health_samples_set_updated_at
    before update on public.health_samples
    for each row execute function public.health_samples_touch_updated_at();
