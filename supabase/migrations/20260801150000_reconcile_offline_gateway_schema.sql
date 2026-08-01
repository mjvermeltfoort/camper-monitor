-- Reconcile the original dashboard schema with the offline gateway RPC payloads.
-- This is a forward-only migration: the first two migrations may already be applied.

alter table public.gateway_devices
    add column if not exists updated_at timestamptz;

update public.gateway_devices
set updated_at = coalesce(updated_at, created_at, now())
where updated_at is null;

alter table public.gateway_devices
    alter column updated_at set default now(),
    alter column updated_at set not null;

alter table public.battery_readings
    add column if not exists sensor_id text,
    add column if not exists sensor_received_at timestamptz,
    add column if not exists consumed_ah double precision,
    add column if not exists time_to_go_minutes integer,
    add column if not exists alarm_reason integer,
    add column if not exists aux_input text,
    add column if not exists aux_voltage_v double precision,
    add column if not exists midpoint_voltage_v double precision,
    add column if not exists temperature_c double precision;

update public.battery_readings
set sensor_id = coalesce(sensor_id, 'legacy'),
    sensor_received_at = coalesce(sensor_received_at, recorded_at),
    alarm_reason = coalesce(alarm_reason, 0),
    aux_input = coalesce(aux_input, 'NONE')
where sensor_id is null
   or sensor_received_at is null
   or alarm_reason is null
   or aux_input is null;

alter table public.battery_readings
    alter column sensor_id set not null,
    alter column sensor_received_at set not null,
    alter column alarm_reason set not null,
    alter column aux_input set not null,
    alter column soc_pct drop not null,
    alter column voltage_v drop not null,
    alter column current_a drop not null,
    alter column power_w drop not null;

alter table public.battery_readings
    drop constraint if exists battery_readings_sensor_id_check,
    drop constraint if exists battery_readings_time_to_go_minutes_check,
    drop constraint if exists battery_readings_alarm_reason_check,
    drop constraint if exists battery_readings_aux_input_check;

alter table public.battery_readings
    add constraint battery_readings_sensor_id_check check (length(sensor_id) between 1 and 100),
    add constraint battery_readings_time_to_go_minutes_check check (time_to_go_minutes >= 0),
    add constraint battery_readings_alarm_reason_check check (alarm_reason between 0 and 65535),
    add constraint battery_readings_aux_input_check
        check (aux_input in ('AUX_VOLTAGE', 'MIDPOINT_VOLTAGE', 'TEMPERATURE', 'NONE'));

alter table public.gas_readings
    add column if not exists sensor_id text,
    add column if not exists sensor_received_at timestamptz,
    add column if not exists level_mm double precision,
    add column if not exists estimated_from_profile boolean,
    add column if not exists sensor_battery_v double precision,
    add column if not exists quality integer,
    add column if not exists sync_button_pressed boolean;

update public.gas_readings
set sensor_id = coalesce(sensor_id, 'legacy'),
    sensor_received_at = coalesce(sensor_received_at, recorded_at),
    level_mm = coalesce(level_mm, 0),
    estimated_from_profile = coalesce(estimated_from_profile, true),
    sensor_battery_v = coalesce(sensor_battery_v, 0),
    quality = coalesce(quality, 0),
    sync_button_pressed = coalesce(sync_button_pressed, false)
where sensor_id is null
   or sensor_received_at is null
   or level_mm is null
   or estimated_from_profile is null
   or sensor_battery_v is null
   or quality is null
   or sync_button_pressed is null;

alter table public.gas_readings
    alter column sensor_id set not null,
    alter column sensor_received_at set not null,
    alter column level_mm set not null,
    alter column estimated_from_profile set not null,
    alter column sensor_battery_v set not null,
    alter column quality set not null,
    alter column sync_button_pressed set not null;

alter table public.gas_readings
    drop constraint if exists gas_readings_sensor_id_check,
    drop constraint if exists gas_readings_level_mm_check,
    drop constraint if exists gas_readings_estimated_from_profile_check,
    drop constraint if exists gas_readings_sensor_battery_v_check,
    drop constraint if exists gas_readings_quality_check;

alter table public.gas_readings
    add constraint gas_readings_sensor_id_check check (length(sensor_id) between 1 and 100),
    add constraint gas_readings_level_mm_check check (level_mm >= 0),
    add constraint gas_readings_estimated_from_profile_check check (estimated_from_profile),
    add constraint gas_readings_sensor_battery_v_check check (sensor_battery_v >= 0),
    add constraint gas_readings_quality_check check (quality between 0 and 3);

alter table public.location_readings
    add column if not exists altitude_m double precision,
    alter column accuracy_m drop not null;

create index if not exists battery_readings_device_recorded_idx
    on public.battery_readings (device_id, recorded_at desc);
create index if not exists gas_readings_device_recorded_idx
    on public.gas_readings (device_id, recorded_at desc);
create index if not exists gateway_readings_device_recorded_idx
    on public.gateway_readings (device_id, recorded_at desc);
create index if not exists location_readings_device_recorded_idx
    on public.location_readings (device_id, recorded_at desc);

drop policy if exists "assigned gateways can insert battery readings" on public.battery_readings;
drop policy if exists "assigned gateways can insert gas readings" on public.gas_readings;
drop policy if exists "assigned gateways can insert gateway readings" on public.gateway_readings;
drop policy if exists "assigned gateways can insert location readings" on public.location_readings;

create or replace function public.register_gateway(p_name text)
returns table(gateway_id uuid, enabled boolean)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    caller uuid := auth.uid();
begin
    if caller is null
       or coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) is not true then
        raise exception 'anonymous authenticated user required' using errcode = '42501';
    end if;
    if length(trim(p_name)) not between 1 and 80 then
        raise exception 'invalid gateway name' using errcode = '22023';
    end if;

    return query
    insert into public.gateway_devices as gd(auth_user_id, name)
    values (caller, trim(p_name))
    on conflict (auth_user_id) do update
        set name = excluded.name,
            updated_at = now()
    returning gd.id, gd.enabled;
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
    if caller is null
       or coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) is not true then
        raise exception 'anonymous authenticated user required' using errcode = '42501';
    end if;
    if jsonb_typeof(p_battery_readings) <> 'array'
       or jsonb_array_length(p_battery_readings) > 100
       or jsonb_typeof(p_gas_readings) <> 'array'
       or jsonb_array_length(p_gas_readings) > 100
       or jsonb_typeof(p_gateway_readings) <> 'array'
       or jsonb_array_length(p_gateway_readings) > 100
       or jsonb_typeof(p_location_readings) <> 'array'
       or jsonb_array_length(p_location_readings) > 100 then
        raise exception 'each reading batch must be an array with at most 100 items'
            using errcode = '22023';
    end if;

    select gd.id
    into gateway
    from public.gateway_devices as gd
    where gd.auth_user_id = caller
      and gd.enabled is true;

    if gateway is null then
        raise exception 'gateway missing or disabled' using errcode = '42501';
    end if;

    insert into public.battery_readings(
        id, device_id, sensor_id, recorded_at, received_at, sensor_received_at,
        soc_pct, voltage_v, current_a, power_w, consumed_ah, time_to_go_minutes,
        alarm_reason, aux_input, aux_voltage_v, midpoint_voltage_v, temperature_c
    )
    select x.id, gateway, x.sensor_id, x.recorded_at, now(), x.sensor_received_at,
        x.soc_pct, x.voltage_v, x.current_a, x.power_w, x.consumed_ah,
        x.time_to_go_minutes, x.alarm_reason, x.aux_input, x.aux_voltage_v,
        x.midpoint_voltage_v, x.temperature_c
    from jsonb_to_recordset(p_battery_readings) as x(
        id uuid, sensor_id text, recorded_at timestamptz, sensor_received_at timestamptz,
        soc_pct double precision, voltage_v double precision, current_a double precision,
        power_w double precision, consumed_ah double precision,
        time_to_go_minutes integer, alarm_reason integer, aux_input text,
        aux_voltage_v double precision, midpoint_voltage_v double precision,
        temperature_c double precision
    )
    on conflict (id) do nothing;
    get diagnostics battery_count = row_count;

    insert into public.gas_readings(
        id, device_id, sensor_id, recorded_at, received_at, sensor_received_at,
        level_mm, fill_pct, mass_kg, estimated_from_profile, temperature_c,
        sensor_battery_v, sensor_battery_pct, quality, sync_button_pressed
    )
    select x.id, gateway, x.sensor_id, x.recorded_at, now(), x.sensor_received_at,
        x.level_mm, x.level_pct, x.mass_kg, x.estimated_from_profile,
        x.temperature_c, x.sensor_battery_v, x.sensor_battery_pct, x.quality,
        x.sync_button_pressed
    from jsonb_to_recordset(p_gas_readings) as x(
        id uuid, sensor_id text, recorded_at timestamptz, sensor_received_at timestamptz,
        level_mm double precision, level_pct double precision, mass_kg double precision,
        estimated_from_profile boolean, temperature_c double precision,
        sensor_battery_v double precision, sensor_battery_pct double precision,
        quality integer, sync_button_pressed boolean
    )
    on conflict (id) do nothing;
    get diagnostics gas_count = row_count;

    insert into public.gateway_readings(
        id, device_id, recorded_at, received_at, phone_battery_pct, is_charging,
        network_type, location_enabled, signal_pct
    )
    select x.id, gateway, x.recorded_at, now(), x.battery_pct, x.charging,
        x.network_type, x.location_enabled, x.signal_pct
    from jsonb_to_recordset(p_gateway_readings) as x(
        id uuid, recorded_at timestamptz, battery_pct double precision,
        charging boolean, network_type text, location_enabled boolean,
        signal_pct double precision
    )
    on conflict (id) do nothing;
    get diagnostics gateway_count = row_count;

    insert into public.location_readings(
        id, device_id, recorded_at, received_at, latitude, longitude, accuracy_m,
        altitude_m, address
    )
    select x.id, gateway, x.recorded_at, now(), x.latitude, x.longitude,
        x.accuracy_m, x.altitude_m, x.address
    from jsonb_to_recordset(p_location_readings) as x(
        id uuid, recorded_at timestamptz, latitude double precision,
        longitude double precision, accuracy_m double precision,
        altitude_m double precision, address text
    )
    on conflict (id) do nothing;
    get diagnostics location_count = row_count;

    return jsonb_build_object(
        'battery', battery_count,
        'gas', gas_count,
        'gateway', gateway_count,
        'location', location_count
    );
end;
$$;

revoke all on public.battery_readings, public.gas_readings,
    public.gateway_readings, public.location_readings
    from anon, authenticated;
grant select on public.authorized_viewers, public.camper, public.gateway_devices,
    public.battery_readings, public.gas_readings, public.gateway_readings,
    public.location_readings
    to authenticated;

revoke all on function public.register_gateway(text) from public, anon;
revoke all on function public.ingest_gateway_batch(jsonb, jsonb, jsonb, jsonb)
    from public, anon;
grant execute on function public.register_gateway(text) to authenticated;
grant execute on function public.ingest_gateway_batch(jsonb, jsonb, jsonb, jsonb)
    to authenticated;
