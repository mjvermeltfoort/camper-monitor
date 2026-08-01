create extension if not exists pgcrypto;

create table public.authorized_viewers (
  user_id uuid primary key references auth.users(id) on delete cascade,
  role text not null default 'viewer' check (role in ('owner', 'viewer')),
  created_at timestamptz not null default now()
);

create table public.camper (
  id uuid primary key default gen_random_uuid(),
  singleton boolean not null default true unique check (singleton),
  name text not null check (length(trim(name)) between 1 and 80),
  vehicle_model text not null check (length(trim(vehicle_model)) between 1 and 120),
  battery_warning_pct smallint not null default 30 check (battery_warning_pct between 1 and 99),
  battery_critical_pct smallint not null default 15 check (battery_critical_pct between 0 and 98),
  gas_warning_pct smallint not null default 25 check (gas_warning_pct between 1 and 99),
  gas_critical_pct smallint not null default 10 check (gas_critical_pct between 0 and 98),
  phone_warning_pct smallint not null default 20 check (phone_warning_pct between 1 and 99),
  stale_after_minutes smallint not null default 5 check (stale_after_minutes between 1 and 1440),
  offline_after_minutes smallint not null default 10 check (offline_after_minutes between 1 and 1440),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint battery_threshold_order check (battery_critical_pct < battery_warning_pct),
  constraint gas_threshold_order check (gas_critical_pct < gas_warning_pct),
  constraint stale_threshold_order check (stale_after_minutes <= offline_after_minutes)
);

create table public.gateway_devices (
  id uuid primary key default gen_random_uuid(),
  auth_user_id uuid not null unique references auth.users(id) on delete cascade,
  name text not null check (length(trim(name)) between 1 and 80),
  enabled boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.battery_readings (
  id uuid primary key,
  device_id uuid not null references public.gateway_devices(id) on delete restrict,
  recorded_at timestamptz not null,
  received_at timestamptz not null default now(),
  soc_pct numeric(5,2) not null check (soc_pct between 0 and 100),
  voltage_v numeric(7,3) not null check (voltage_v >= 0),
  current_a numeric(9,3) not null,
  power_w numeric(10,2) not null
);

create table public.gas_readings (
  id uuid primary key,
  device_id uuid not null references public.gateway_devices(id) on delete restrict,
  recorded_at timestamptz not null,
  received_at timestamptz not null default now(),
  fill_pct numeric(5,2) not null check (fill_pct between 0 and 100),
  mass_kg numeric(7,3) not null check (mass_kg >= 0),
  temperature_c numeric(6,2) not null,
  sensor_battery_pct numeric(5,2) check (sensor_battery_pct between 0 and 100)
);

create table public.gateway_readings (
  id uuid primary key,
  device_id uuid not null references public.gateway_devices(id) on delete restrict,
  recorded_at timestamptz not null,
  received_at timestamptz not null default now(),
  phone_battery_pct numeric(5,2) not null check (phone_battery_pct between 0 and 100),
  is_charging boolean not null,
  network_type text not null check (length(trim(network_type)) between 1 and 32),
  signal_pct numeric(5,2) check (signal_pct between 0 and 100),
  location_enabled boolean not null
);

create table public.location_readings (
  id uuid primary key,
  device_id uuid not null references public.gateway_devices(id) on delete restrict,
  recorded_at timestamptz not null,
  received_at timestamptz not null default now(),
  latitude double precision not null check (latitude between -90 and 90),
  longitude double precision not null check (longitude between -180 and 180),
  accuracy_m numeric(9,2) not null check (accuracy_m >= 0),
  address text check (address is null or length(address) <= 300)
);

create index battery_readings_recorded_at_idx on public.battery_readings (recorded_at desc);
create index gas_readings_recorded_at_idx on public.gas_readings (recorded_at desc);
create index gateway_readings_recorded_at_idx on public.gateway_readings (recorded_at desc);
create index location_readings_recorded_at_idx on public.location_readings (recorded_at desc);

create function public.set_camper_updated_at()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger camper_set_updated_at
before update on public.camper
for each row execute function public.set_camper_updated_at();

alter table public.authorized_viewers enable row level security;
alter table public.camper enable row level security;
alter table public.gateway_devices enable row level security;
alter table public.battery_readings enable row level security;
alter table public.gas_readings enable row level security;
alter table public.gateway_readings enable row level security;
alter table public.location_readings enable row level security;

create policy "viewers can read their authorization"
on public.authorized_viewers for select to authenticated
using ((select auth.uid()) = user_id);

create policy "authorized viewers can read camper"
on public.camper for select to authenticated
using (exists (
  select 1 from public.authorized_viewers v where v.user_id = (select auth.uid())
));

create policy "authorized viewers can read devices"
on public.gateway_devices for select to authenticated
using (exists (
  select 1 from public.authorized_viewers v where v.user_id = (select auth.uid())
));

create policy "gateways can read their own assignment"
on public.gateway_devices for select to authenticated
using (auth_user_id = (select auth.uid()));

create policy "authorized viewers can read battery readings"
on public.battery_readings for select to authenticated
using (exists (
  select 1 from public.authorized_viewers v where v.user_id = (select auth.uid())
));

create policy "assigned gateways can insert battery readings"
on public.battery_readings for insert to authenticated
with check (exists (
  select 1 from public.gateway_devices d
  where d.id = device_id and d.auth_user_id = (select auth.uid()) and d.enabled
));

create policy "authorized viewers can read gas readings"
on public.gas_readings for select to authenticated
using (exists (
  select 1 from public.authorized_viewers v where v.user_id = (select auth.uid())
));

create policy "assigned gateways can insert gas readings"
on public.gas_readings for insert to authenticated
with check (exists (
  select 1 from public.gateway_devices d
  where d.id = device_id and d.auth_user_id = (select auth.uid()) and d.enabled
));

create policy "authorized viewers can read gateway readings"
on public.gateway_readings for select to authenticated
using (exists (
  select 1 from public.authorized_viewers v where v.user_id = (select auth.uid())
));

create policy "assigned gateways can insert gateway readings"
on public.gateway_readings for insert to authenticated
with check (exists (
  select 1 from public.gateway_devices d
  where d.id = device_id and d.auth_user_id = (select auth.uid()) and d.enabled
));

create policy "authorized viewers can read location readings"
on public.location_readings for select to authenticated
using (exists (
  select 1 from public.authorized_viewers v where v.user_id = (select auth.uid())
));

create policy "assigned gateways can insert location readings"
on public.location_readings for insert to authenticated
with check (exists (
  select 1 from public.gateway_devices d
  where d.id = device_id and d.auth_user_id = (select auth.uid()) and d.enabled
));

create function public.get_dashboard_state()
returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  result jsonb;
begin
  select jsonb_build_object(
    'server_time', now(),
    'camper', to_jsonb(c) - 'singleton',
    'battery', (
      select to_jsonb(b) - 'device_id' from public.battery_readings b
      order by b.recorded_at desc limit 1
    ),
    'gas', (
      select to_jsonb(g) - 'device_id' from public.gas_readings g
      order by g.recorded_at desc limit 1
    ),
    'gateway', (
      select (to_jsonb(gr) - 'device_id') || jsonb_build_object('device_name', d.name)
      from public.gateway_readings gr
      join public.gateway_devices d on d.id = gr.device_id
      order by gr.recorded_at desc limit 1
    ),
    'location', (
      select to_jsonb(l) - 'device_id' from public.location_readings l
      order by l.recorded_at desc limit 1
    )
  ) into result
  from public.camper c
  where c.singleton;

  if result is null then
    raise exception 'No camper access is assigned to this user' using errcode = '42501';
  end if;

  return result;
end;
$$;

create function public.get_dashboard_history(p_range text)
returns table (
  bucket_at timestamptz,
  battery_soc_pct numeric,
  gas_fill_pct numeric
)
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  range_interval interval;
  bucket_interval interval;
begin
  if p_range = '24h' then
    range_interval := interval '24 hours';
    bucket_interval := interval '1 hour';
  elsif p_range = '7d' then
    range_interval := interval '7 days';
    bucket_interval := interval '6 hours';
  elsif p_range = '30d' then
    range_interval := interval '30 days';
    bucket_interval := interval '1 day';
  else
    raise exception 'Unsupported history range: %', p_range using errcode = '22023';
  end if;

  if not exists (select 1 from public.camper c where c.singleton) then
    raise exception 'No camper access is assigned to this user' using errcode = '42501';
  end if;

  return query
  with battery as (
    select distinct on (date_bin(bucket_interval, b.recorded_at, timestamptz '2001-01-01'))
      date_bin(bucket_interval, b.recorded_at, timestamptz '2001-01-01') as bucket,
      b.soc_pct
    from public.battery_readings b
    where b.recorded_at >= now() - range_interval
    order by date_bin(bucket_interval, b.recorded_at, timestamptz '2001-01-01'), b.recorded_at desc
  ), gas as (
    select distinct on (date_bin(bucket_interval, g.recorded_at, timestamptz '2001-01-01'))
      date_bin(bucket_interval, g.recorded_at, timestamptz '2001-01-01') as bucket,
      g.fill_pct
    from public.gas_readings g
    where g.recorded_at >= now() - range_interval
    order by date_bin(bucket_interval, g.recorded_at, timestamptz '2001-01-01'), g.recorded_at desc
  )
  select coalesce(battery.bucket, gas.bucket), battery.soc_pct, gas.fill_pct
  from battery full join gas on gas.bucket = battery.bucket
  order by coalesce(battery.bucket, gas.bucket);
end;
$$;

revoke all on public.authorized_viewers, public.camper, public.gateway_devices,
  public.battery_readings, public.gas_readings, public.gateway_readings,
  public.location_readings from anon;
revoke all on public.authorized_viewers, public.camper, public.gateway_devices,
  public.battery_readings, public.gas_readings, public.gateway_readings,
  public.location_readings from authenticated;

grant select on public.authorized_viewers, public.camper, public.gateway_devices,
  public.battery_readings, public.gas_readings, public.gateway_readings,
  public.location_readings to authenticated;
grant insert (id, device_id, recorded_at, soc_pct, voltage_v, current_a, power_w)
  on public.battery_readings to authenticated;
grant insert (id, device_id, recorded_at, fill_pct, mass_kg, temperature_c, sensor_battery_pct)
  on public.gas_readings to authenticated;
grant insert (id, device_id, recorded_at, phone_battery_pct, is_charging, network_type, signal_pct, location_enabled)
  on public.gateway_readings to authenticated;
grant insert (id, device_id, recorded_at, latitude, longitude, accuracy_m, address)
  on public.location_readings to authenticated;

revoke all on function public.set_camper_updated_at() from public, anon, authenticated;
revoke all on function public.get_dashboard_state() from public, anon;
revoke all on function public.get_dashboard_history(text) from public, anon;
grant execute on function public.get_dashboard_state() to authenticated;
grant execute on function public.get_dashboard_history(text) to authenticated;

