create extension if not exists pgcrypto;

create table if not exists public.authorized_viewers (
    user_id uuid primary key references auth.users(id) on delete cascade,
    created_at timestamptz not null default now()
);

create table if not exists public.gateway_devices (
    id uuid primary key default gen_random_uuid(),
    auth_user_id uuid not null unique references auth.users(id) on delete cascade,
    name text not null check (length(trim(name)) between 1 and 100),
    enabled boolean not null default true,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create table if not exists public.battery_readings (
    id uuid primary key,
    device_id uuid not null references public.gateway_devices(id),
    sensor_id text not null check (length(sensor_id) between 1 and 100),
    recorded_at timestamptz not null,
    received_at timestamptz not null default now(),
    sensor_received_at timestamptz not null,
    soc_pct double precision check (soc_pct between 0 and 100),
    voltage_v double precision,
    current_a double precision,
    power_w double precision,
    consumed_ah double precision,
    time_to_go_minutes integer check (time_to_go_minutes >= 0),
    alarm_reason integer not null check (alarm_reason between 0 and 65535),
    aux_input text not null check (aux_input in ('AUX_VOLTAGE','MIDPOINT_VOLTAGE','TEMPERATURE','NONE')),
    aux_voltage_v double precision,
    midpoint_voltage_v double precision,
    temperature_c double precision
);

create table if not exists public.gas_readings (
    id uuid primary key,
    device_id uuid not null references public.gateway_devices(id),
    sensor_id text not null check (length(sensor_id) between 1 and 100),
    recorded_at timestamptz not null,
    received_at timestamptz not null default now(),
    sensor_received_at timestamptz not null,
    level_mm double precision not null check (level_mm >= 0),
    level_pct double precision not null check (level_pct between 0 and 100),
    mass_kg double precision not null check (mass_kg >= 0),
    estimated_from_profile boolean not null check (estimated_from_profile),
    temperature_c double precision not null,
    sensor_battery_v double precision not null check (sensor_battery_v >= 0),
    sensor_battery_pct double precision check (sensor_battery_pct between 0 and 100),
    quality integer not null check (quality between 0 and 3),
    sync_button_pressed boolean not null
);

create table if not exists public.gateway_readings (
    id uuid primary key,
    device_id uuid not null references public.gateway_devices(id),
    recorded_at timestamptz not null,
    received_at timestamptz not null default now(),
    battery_pct double precision not null check (battery_pct between 0 and 100),
    charging boolean not null,
    network_type text not null check (network_type in ('none','wifi','cellular','ethernet','vpn','other')),
    location_enabled boolean not null,
    signal_pct double precision check (signal_pct between 0 and 100)
);

create table if not exists public.location_readings (
    id uuid primary key,
    device_id uuid not null references public.gateway_devices(id),
    recorded_at timestamptz not null,
    received_at timestamptz not null default now(),
    latitude double precision not null check (latitude between -90 and 90),
    longitude double precision not null check (longitude between -180 and 180),
    accuracy_m double precision check (accuracy_m >= 0),
    altitude_m double precision,
    address text
);

create index if not exists battery_readings_device_recorded_idx on public.battery_readings (device_id, recorded_at desc);
create index if not exists gas_readings_device_recorded_idx on public.gas_readings (device_id, recorded_at desc);
create index if not exists gateway_readings_device_recorded_idx on public.gateway_readings (device_id, recorded_at desc);
create index if not exists location_readings_device_recorded_idx on public.location_readings (device_id, recorded_at desc);

alter table public.authorized_viewers enable row level security;
alter table public.gateway_devices enable row level security;
alter table public.battery_readings enable row level security;
alter table public.gas_readings enable row level security;
alter table public.gateway_readings enable row level security;
alter table public.location_readings enable row level security;

drop policy if exists "authorized viewers read battery" on public.battery_readings;
create policy "authorized viewers read battery" on public.battery_readings for select to authenticated
using (exists (select 1 from public.authorized_viewers v where v.user_id = auth.uid()));
drop policy if exists "authorized viewers read gas" on public.gas_readings;
create policy "authorized viewers read gas" on public.gas_readings for select to authenticated
using (exists (select 1 from public.authorized_viewers v where v.user_id = auth.uid()));
drop policy if exists "authorized viewers read gateway" on public.gateway_readings;
create policy "authorized viewers read gateway" on public.gateway_readings for select to authenticated
using (exists (select 1 from public.authorized_viewers v where v.user_id = auth.uid()));
drop policy if exists "authorized viewers read location" on public.location_readings;
create policy "authorized viewers read location" on public.location_readings for select to authenticated
using (exists (select 1 from public.authorized_viewers v where v.user_id = auth.uid()));

create or replace function public.register_gateway(p_name text)
returns table(gateway_id uuid, enabled boolean)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    caller uuid := auth.uid();
begin
    if caller is null or coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) is not true then
        raise exception 'anonymous authenticated user required' using errcode = '42501';
    end if;
    if length(trim(p_name)) not between 1 and 100 then
        raise exception 'invalid gateway name' using errcode = '22023';
    end if;
    return query
    insert into public.gateway_devices(auth_user_id, name)
    values (caller, trim(p_name))
    on conflict (auth_user_id) do update
        set name = excluded.name, updated_at = now()
    returning gateway_devices.id, gateway_devices.enabled;
end;
$$;

create or replace function public.ingest_gateway_batch(
    p_battery_readings jsonb default '[]'::jsonb,
    p_gas_readings jsonb default '[]'::jsonb,
    p_gateway_readings jsonb default '[]'::jsonb,
    p_location_readings jsonb default '[]'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    caller uuid := auth.uid();
    gateway uuid;
    battery_count integer := 0;
    gas_count integer := 0;
    gateway_count integer := 0;
    location_count integer := 0;
begin
    if caller is null or coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) is not true then
        raise exception 'anonymous authenticated user required' using errcode = '42501';
    end if;
    if jsonb_typeof(p_battery_readings) <> 'array' or jsonb_array_length(p_battery_readings) > 100
       or jsonb_typeof(p_gas_readings) <> 'array' or jsonb_array_length(p_gas_readings) > 100
       or jsonb_typeof(p_gateway_readings) <> 'array' or jsonb_array_length(p_gateway_readings) > 100
       or jsonb_typeof(p_location_readings) <> 'array' or jsonb_array_length(p_location_readings) > 100 then
        raise exception 'each reading batch must be an array with at most 100 items' using errcode = '22023';
    end if;
    select id into gateway from public.gateway_devices where auth_user_id = caller and enabled is true;
    if gateway is null then raise exception 'gateway missing or disabled' using errcode = '42501'; end if;

    insert into public.battery_readings(
        id, device_id, sensor_id, recorded_at, received_at, sensor_received_at, soc_pct, voltage_v,
        current_a, power_w, consumed_ah, time_to_go_minutes, alarm_reason, aux_input,
        aux_voltage_v, midpoint_voltage_v, temperature_c
    ) select x.id, gateway, x.sensor_id, x.recorded_at, now(), x.sensor_received_at, x.soc_pct,
        x.voltage_v, x.current_a, x.power_w, x.consumed_ah, x.time_to_go_minutes,
        x.alarm_reason, x.aux_input, x.aux_voltage_v, x.midpoint_voltage_v, x.temperature_c
    from jsonb_to_recordset(p_battery_readings) as x(
        id uuid, sensor_id text, recorded_at timestamptz, sensor_received_at timestamptz,
        soc_pct double precision, voltage_v double precision, current_a double precision,
        power_w double precision, consumed_ah double precision, time_to_go_minutes integer,
        alarm_reason integer, aux_input text, aux_voltage_v double precision,
        midpoint_voltage_v double precision, temperature_c double precision
    ) on conflict (id) do nothing;
    get diagnostics battery_count = row_count;

    insert into public.gas_readings(
        id, device_id, sensor_id, recorded_at, received_at, sensor_received_at, level_mm, level_pct,
        mass_kg, estimated_from_profile, temperature_c, sensor_battery_v, sensor_battery_pct,
        quality, sync_button_pressed
    ) select x.id, gateway, x.sensor_id, x.recorded_at, now(), x.sensor_received_at, x.level_mm,
        x.level_pct, x.mass_kg, x.estimated_from_profile, x.temperature_c, x.sensor_battery_v,
        x.sensor_battery_pct, x.quality, x.sync_button_pressed
    from jsonb_to_recordset(p_gas_readings) as x(
        id uuid, sensor_id text, recorded_at timestamptz, sensor_received_at timestamptz,
        level_mm double precision, level_pct double precision, mass_kg double precision,
        estimated_from_profile boolean, temperature_c double precision, sensor_battery_v double precision,
        sensor_battery_pct double precision, quality integer, sync_button_pressed boolean
    ) on conflict (id) do nothing;
    get diagnostics gas_count = row_count;

    insert into public.gateway_readings(id, device_id, recorded_at, received_at, battery_pct, charging, network_type, location_enabled, signal_pct)
    select x.id, gateway, x.recorded_at, now(), x.battery_pct, x.charging, x.network_type, x.location_enabled, x.signal_pct
    from jsonb_to_recordset(p_gateway_readings) as x(
        id uuid, recorded_at timestamptz, battery_pct double precision, charging boolean,
        network_type text, location_enabled boolean, signal_pct double precision
    ) on conflict (id) do nothing;
    get diagnostics gateway_count = row_count;

    insert into public.location_readings(id, device_id, recorded_at, received_at, latitude, longitude, accuracy_m, altitude_m, address)
    select x.id, gateway, x.recorded_at, now(), x.latitude, x.longitude, x.accuracy_m, x.altitude_m, x.address
    from jsonb_to_recordset(p_location_readings) as x(
        id uuid, recorded_at timestamptz, latitude double precision, longitude double precision,
        accuracy_m double precision, altitude_m double precision, address text
    ) on conflict (id) do nothing;
    get diagnostics location_count = row_count;

    return jsonb_build_object('battery', battery_count, 'gas', gas_count, 'gateway', gateway_count, 'location', location_count);
end;
$$;

create or replace function public.dashboard_latest()
returns jsonb language sql stable security invoker set search_path = public, pg_temp
as $$
select jsonb_build_object(
    'battery', (select to_jsonb(r) from public.battery_readings r order by recorded_at desc limit 1),
    'gas', (select to_jsonb(r) from public.gas_readings r order by recorded_at desc limit 1),
    'gateway', (select to_jsonb(r) from public.gateway_readings r order by recorded_at desc limit 1),
    'location', (select to_jsonb(r) from public.location_readings r order by recorded_at desc limit 1)
);
$$;

revoke all on public.authorized_viewers, public.gateway_devices,
    public.battery_readings, public.gas_readings, public.gateway_readings, public.location_readings
    from anon, authenticated;
grant select on public.battery_readings, public.gas_readings, public.gateway_readings, public.location_readings to authenticated;
revoke all on function public.register_gateway(text) from public, anon;
revoke all on function public.ingest_gateway_batch(jsonb, jsonb, jsonb, jsonb) from public, anon;
grant execute on function public.register_gateway(text) to authenticated;
grant execute on function public.ingest_gateway_batch(jsonb, jsonb, jsonb, jsonb) to authenticated;
grant execute on function public.dashboard_latest() to authenticated;
