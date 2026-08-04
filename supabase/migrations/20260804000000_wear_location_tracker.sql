begin;

alter table public.gateway_devices
    add column if not exists device_kind text not null default 'camper_gateway';

alter table public.gateway_devices
    drop constraint if exists gateway_devices_device_kind_check;
alter table public.gateway_devices
    add constraint gateway_devices_device_kind_check
    check (device_kind in ('camper_gateway', 'wear_tracker'));

create table public.tracking_sessions (
    id uuid primary key,
    device_id uuid not null references public.gateway_devices(id) on delete restrict,
    started_at timestamptz not null,
    ended_at timestamptz,
    latest_sample_at timestamptz not null,
    distance_m double precision not null default 0 check (distance_m >= 0),
    steps bigint not null default 0 check (steps >= 0),
    calories_kcal double precision not null default 0 check (calories_kcal >= 0),
    elevation_gain_m double precision not null default 0 check (elevation_gain_m >= 0),
    elevation_loss_m double precision not null default 0 check (elevation_loss_m >= 0),
    average_heart_rate_bpm double precision check (average_heart_rate_bpm between 0 and 260),
    max_heart_rate_bpm double precision check (max_heart_rate_bpm between 0 and 260),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    check (ended_at is null or ended_at >= started_at),
    check (latest_sample_at >= started_at)
);

alter table public.location_readings
    add column if not exists session_id uuid references public.tracking_sessions(id) on delete restrict;

create table public.tracking_metric_samples (
    id uuid primary key,
    session_id uuid not null references public.tracking_sessions(id) on delete restrict,
    device_id uuid not null references public.gateway_devices(id) on delete restrict,
    recorded_at timestamptz not null,
    received_at timestamptz not null default now(),
    heart_rate_bpm double precision check (heart_rate_bpm between 0 and 260),
    speed_mps double precision check (speed_mps >= 0),
    pace_seconds_per_km double precision check (pace_seconds_per_km >= 0),
    cadence_spm double precision check (cadence_spm >= 0),
    elevation_m double precision,
    distance_m double precision check (distance_m >= 0),
    steps bigint check (steps >= 0),
    calories_kcal double precision check (calories_kcal >= 0)
);

create index tracking_sessions_device_started_idx
    on public.tracking_sessions(device_id, started_at desc);
create index tracking_sessions_active_idx
    on public.tracking_sessions(device_id, latest_sample_at desc) where ended_at is null;
create index tracking_metric_samples_session_recorded_idx
    on public.tracking_metric_samples(session_id, recorded_at);
create index tracking_metric_samples_device_recorded_idx
    on public.tracking_metric_samples(device_id, recorded_at desc);
create index if not exists location_readings_device_session_recorded_idx
    on public.location_readings(device_id, session_id, recorded_at);

alter table public.tracking_sessions enable row level security;
alter table public.tracking_metric_samples enable row level security;

create policy "authorized viewers read tracking sessions"
on public.tracking_sessions for select to authenticated
using (exists (
    select 1 from public.authorized_viewers v where v.user_id = (select auth.uid())
));

create policy "authorized viewers read tracking metrics"
on public.tracking_metric_samples for select to authenticated
using (exists (
    select 1 from public.authorized_viewers v where v.user_id = (select auth.uid())
));

create or replace function public.register_location_tracker(p_name text)
returns table(device_id uuid, enabled boolean)
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
        raise exception 'invalid tracker name' using errcode = '22023';
    end if;

    return query
    insert into public.gateway_devices as gd(auth_user_id, name, device_kind)
    values (caller, trim(p_name), 'wear_tracker')
    on conflict (auth_user_id) do update
        set name = excluded.name,
            updated_at = now()
        where gd.device_kind = 'wear_tracker'
    returning gd.id, gd.enabled;
    if not found then
        raise exception 'this identity belongs to another device kind' using errcode = '42501';
    end if;
end;
$$;

create or replace function public.ingest_location_tracker_batch(
    p_session jsonb,
    p_location_readings jsonb default '[]'::jsonb,
    p_metric_samples jsonb default '[]'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    caller uuid := auth.uid();
    tracker uuid;
    session_uuid uuid;
    location_count integer := 0;
    metric_count integer := 0;
begin
    if caller is null
       or coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) is not true then
        raise exception 'anonymous authenticated user required' using errcode = '42501';
    end if;
    if coalesce(jsonb_typeof(p_session), 'null') <> 'object'
       or coalesce(jsonb_typeof(p_location_readings), 'null') <> 'array'
       or jsonb_array_length(p_location_readings) > 100
       or coalesce(jsonb_typeof(p_metric_samples), 'null') <> 'array'
       or jsonb_array_length(p_metric_samples) > 100 then
        raise exception 'session must be an object and each collection an array with at most 100 items'
            using errcode = '22023';
    end if;

    select gd.id into tracker
    from public.gateway_devices gd
    where gd.auth_user_id = caller
      and gd.device_kind = 'wear_tracker'
      and gd.enabled is true;
    if tracker is null then
        raise exception 'tracker missing or disabled' using errcode = '42501';
    end if;

    session_uuid := (p_session ->> 'id')::uuid;
    insert into public.tracking_sessions as ts(
        id, device_id, started_at, ended_at, latest_sample_at, distance_m, steps,
        calories_kcal, elevation_gain_m, elevation_loss_m,
        average_heart_rate_bpm, max_heart_rate_bpm
    ) values (
        session_uuid,
        tracker,
        (p_session ->> 'started_at')::timestamptz,
        nullif(p_session ->> 'ended_at', '')::timestamptz,
        (p_session ->> 'latest_sample_at')::timestamptz,
        coalesce((p_session ->> 'distance_m')::double precision, 0),
        coalesce((p_session ->> 'steps')::bigint, 0),
        coalesce((p_session ->> 'calories_kcal')::double precision, 0),
        coalesce((p_session ->> 'elevation_gain_m')::double precision, 0),
        coalesce((p_session ->> 'elevation_loss_m')::double precision, 0),
        nullif(p_session ->> 'average_heart_rate_bpm', '')::double precision,
        nullif(p_session ->> 'max_heart_rate_bpm', '')::double precision
    )
    on conflict (id) do update set
        ended_at = excluded.ended_at,
        latest_sample_at = excluded.latest_sample_at,
        distance_m = excluded.distance_m,
        steps = excluded.steps,
        calories_kcal = excluded.calories_kcal,
        elevation_gain_m = excluded.elevation_gain_m,
        elevation_loss_m = excluded.elevation_loss_m,
        average_heart_rate_bpm = excluded.average_heart_rate_bpm,
        max_heart_rate_bpm = excluded.max_heart_rate_bpm,
        updated_at = now()
    where ts.device_id = tracker
      and excluded.latest_sample_at >= ts.latest_sample_at;

    if not exists (
        select 1 from public.tracking_sessions ts
        where ts.id = session_uuid and ts.device_id = tracker
    ) then
        raise exception 'session is owned by another device' using errcode = '42501';
    end if;

    insert into public.location_readings(
        id, device_id, session_id, recorded_at, received_at, latitude, longitude,
        accuracy_m, altitude_m, address
    )
    select x.id, tracker, session_uuid, x.recorded_at, now(), x.latitude, x.longitude,
        x.accuracy_m, x.altitude_m, null
    from jsonb_to_recordset(p_location_readings) as x(
        id uuid, recorded_at timestamptz, latitude double precision,
        longitude double precision, accuracy_m double precision, altitude_m double precision
    )
    where x.recorded_at >= (select started_at from public.tracking_sessions where id = session_uuid)
    on conflict (id) do nothing;
    get diagnostics location_count = row_count;

    insert into public.tracking_metric_samples(
        id, session_id, device_id, recorded_at, received_at, heart_rate_bpm,
        speed_mps, pace_seconds_per_km, cadence_spm, elevation_m, distance_m,
        steps, calories_kcal
    )
    select x.id, session_uuid, tracker, x.recorded_at, now(), x.heart_rate_bpm,
        x.speed_mps, x.pace_seconds_per_km, x.cadence_spm, x.elevation_m,
        x.distance_m, x.steps, x.calories_kcal
    from jsonb_to_recordset(p_metric_samples) as x(
        id uuid, recorded_at timestamptz, heart_rate_bpm double precision,
        speed_mps double precision, pace_seconds_per_km double precision,
        cadence_spm double precision, elevation_m double precision,
        distance_m double precision, steps bigint, calories_kcal double precision
    )
    where x.recorded_at >= (select started_at from public.tracking_sessions where id = session_uuid)
    on conflict (id) do nothing;
    get diagnostics metric_count = row_count;

    return jsonb_build_object('session', session_uuid, 'location', location_count, 'metrics', metric_count);
end;
$$;

create or replace function public.get_dashboard_state()
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
        'battery', (select to_jsonb(b) - 'device_id' from public.battery_readings b order by b.recorded_at desc limit 1),
        'gas', (select to_jsonb(g) - 'device_id' from public.gas_readings g order by g.recorded_at desc limit 1),
        'gateway', (
            select (to_jsonb(gr) - 'device_id') || jsonb_build_object('device_name', d.name)
            from public.gateway_readings gr join public.gateway_devices d on d.id = gr.device_id
            order by gr.recorded_at desc limit 1
        ),
        'location', (
            select to_jsonb(l) - 'device_id'
            from public.location_readings l
            join public.gateway_devices d on d.id = l.device_id
            where d.device_kind = 'camper_gateway'
            order by l.recorded_at desc limit 1
        ),
        'latest_locations', coalesce((
            select jsonb_agg(to_jsonb(latest) order by latest.device_kind, latest.device_name)
            from (
                select distinct on (l.device_id)
                    l.device_id, d.name as device_name, d.device_kind, d.created_at as registered_at, l.session_id,
                    l.recorded_at, l.received_at, l.latitude, l.longitude,
                    l.accuracy_m, l.altitude_m, l.address
                from public.location_readings l
                join public.gateway_devices d on d.id = l.device_id
                where d.enabled
                order by l.device_id, l.recorded_at desc, l.id
            ) latest
        ), '[]'::jsonb),
        'active_tracking_sessions', coalesce((
            select jsonb_agg((to_jsonb(ts) - 'created_at' - 'updated_at') ||
                jsonb_build_object('device_name', d.name, 'device_kind', d.device_kind)
                order by ts.started_at desc)
            from public.tracking_sessions ts
            join public.gateway_devices d on d.id = ts.device_id
            where ts.ended_at is null
        ), '[]'::jsonb)
    ) into result
    from public.camper c where c.singleton;

    if result is null then
        raise exception 'No camper access is assigned to this user' using errcode = '42501';
    end if;
    return result;
end;
$$;

create or replace function public.location_history_for_device(
    p_device_id uuid,
    p_started_at timestamptz,
    p_downsample_seconds double precision
)
returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
    sample record;
    previous_seen_at timestamptz;
    previous_session uuid;
    anchor_at timestamptz;
    anchor_latitude double precision;
    anchor_longitude double precision;
    anchor_accuracy_m double precision;
    elapsed_seconds double precision;
    leg_distance_m double precision;
    haversine_a double precision;
    total_distance_m double precision := 0;
    segment_point_count integer := 0;
    segment_points jsonb := '[]'::jsonb;
    raw_segments jsonb := '[]'::jsonb;
    route_segments jsonb;
begin
    for sample in
        with eligible as (
            select l.*,
                row_number() over (
                    partition by l.session_id, date_bin(interval '5 seconds', l.recorded_at, timestamptz '2001-01-01')
                    order by l.accuracy_m asc nulls last, l.recorded_at desc, l.id
                ) as accuracy_rank
            from public.location_readings l
            where l.device_id = p_device_id
              and l.recorded_at between p_started_at and now()
              and (l.accuracy_m is null or l.accuracy_m <= 100)
        )
        select * from eligible where accuracy_rank = 1 order by recorded_at, id
    loop
        if anchor_at is null
           or sample.session_id is distinct from previous_session
           or (sample.session_id is null and sample.recorded_at - previous_seen_at > interval '30 minutes') then
            if segment_point_count >= 2 then raw_segments := raw_segments || jsonb_build_array(segment_points); end if;
            anchor_at := sample.recorded_at;
            anchor_latitude := sample.latitude;
            anchor_longitude := sample.longitude;
            anchor_accuracy_m := sample.accuracy_m;
            segment_points := jsonb_build_array(jsonb_build_array(sample.longitude, sample.latitude));
            segment_point_count := 1;
            previous_seen_at := sample.recorded_at;
            previous_session := sample.session_id;
            continue;
        end if;

        previous_seen_at := sample.recorded_at;
        haversine_a := power(sin(radians(sample.latitude - anchor_latitude) / 2), 2)
            + cos(radians(anchor_latitude)) * cos(radians(sample.latitude))
            * power(sin(radians(sample.longitude - anchor_longitude) / 2), 2);
        leg_distance_m := 12742000 * asin(sqrt(least(1, greatest(0, haversine_a))));
        if leg_distance_m <= greatest(10, coalesce(anchor_accuracy_m, 0), coalesce(sample.accuracy_m, 0)) then
            continue;
        end if;
        elapsed_seconds := extract(epoch from sample.recorded_at - anchor_at);
        if elapsed_seconds <= 0 or leg_distance_m / elapsed_seconds * 3.6 > 180 then
            if segment_point_count >= 2 then raw_segments := raw_segments || jsonb_build_array(segment_points); end if;
            segment_points := jsonb_build_array(jsonb_build_array(sample.longitude, sample.latitude));
            segment_point_count := 1;
        else
            total_distance_m := total_distance_m + leg_distance_m;
            segment_points := segment_points || jsonb_build_array(jsonb_build_array(sample.longitude, sample.latitude));
            segment_point_count := segment_point_count + 1;
        end if;
        anchor_at := sample.recorded_at;
        anchor_latitude := sample.latitude;
        anchor_longitude := sample.longitude;
        anchor_accuracy_m := sample.accuracy_m;
        previous_session := sample.session_id;
    end loop;
    if segment_point_count >= 2 then raw_segments := raw_segments || jsonb_build_array(segment_points); end if;

    with points as (
        select segment.ordinality as segment_number, point.ordinality as point_number,
            count(*) over (partition by segment.ordinality) as point_count,
            point.value as coordinates,
            row_number() over (
                partition by segment.ordinality,
                    floor(point.ordinality / greatest(1, p_downsample_seconds / 5))
                order by point.ordinality
            ) as bucket_rank
        from jsonb_array_elements(raw_segments) with ordinality segment(value, ordinality)
        cross join lateral jsonb_array_elements(segment.value) with ordinality point(value, ordinality)
    ), sampled as (
        select segment_number, jsonb_agg(coordinates order by point_number) coordinates
        from points
        where point_number = 1 or point_number = point_count or bucket_rank = 1
        group by segment_number having count(*) >= 2
    )
    select coalesce(jsonb_agg(coordinates order by segment_number), '[]'::jsonb)
    into route_segments from sampled;

    return jsonb_build_object('distance_km', total_distance_m / 1000, 'route_segments', route_segments);
end;
$$;

create or replace function public.get_location_history(p_range text)
returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
    range_interval interval;
    range_started_at timestamptz;
    downsample_seconds double precision;
    device record;
    history jsonb;
    devices jsonb := '[]'::jsonb;
    camper_history jsonb := jsonb_build_object('distance_km', 0, 'route_segments', '[]'::jsonb);
begin
    case p_range
        when '24h' then range_interval := interval '24 hours';
        when '7d' then range_interval := interval '7 days';
        when '30d' then range_interval := interval '30 days';
        else raise exception 'Unsupported location range: %', p_range using errcode = '22023';
    end case;
    if not exists (select 1 from public.camper c where c.singleton) then
        raise exception 'No camper access is assigned to this user' using errcode = '42501';
    end if;
    range_started_at := now() - range_interval;
    downsample_seconds := greatest(5, extract(epoch from range_interval) / 2498);

    for device in
        select d.id, d.name, d.device_kind, d.created_at,
            (select to_jsonb(latest) from (
                select l.recorded_at, l.latitude, l.longitude, l.accuracy_m, l.altitude_m
                from public.location_readings l where l.device_id = d.id
                order by l.recorded_at desc limit 1
            ) latest) as latest_fix
        from public.gateway_devices d
        where d.enabled and exists (
            select 1 from public.location_readings l
            where l.device_id = d.id and l.recorded_at between range_started_at and now()
        )
        order by d.device_kind, d.name, d.id
    loop
        history := public.location_history_for_device(device.id, range_started_at, downsample_seconds);
        devices := devices || jsonb_build_array(jsonb_build_object(
            'device_id', device.id, 'device_name', device.name, 'device_kind', device.device_kind,
            'registered_at', device.created_at,
            'distance_km', history -> 'distance_km', 'latest_fix', device.latest_fix,
            'route_segments', history -> 'route_segments'
        ));
        if device.device_kind = 'camper_gateway' and (camper_history ->> 'distance_km')::double precision = 0 then
            camper_history := history;
        end if;
    end loop;

    return jsonb_build_object(
        'range', p_range,
        'distance_km', camper_history -> 'distance_km',
        'route_segments', camper_history -> 'route_segments',
        'devices', devices
    );
end;
$$;

create or replace function public.get_tracking_sessions(p_range text)
returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
    range_interval interval;
begin
    case p_range
        when '24h' then range_interval := interval '24 hours';
        when '7d' then range_interval := interval '7 days';
        when '30d' then range_interval := interval '30 days';
        else raise exception 'Unsupported tracking range: %', p_range using errcode = '22023';
    end case;
    if not exists (select 1 from public.camper c where c.singleton) then
        raise exception 'No camper access is assigned to this user' using errcode = '42501';
    end if;
    return coalesce((
        select jsonb_agg((to_jsonb(ts) - 'created_at' - 'updated_at') ||
            jsonb_build_object('device_name', d.name, 'device_kind', d.device_kind)
            order by ts.started_at desc)
        from public.tracking_sessions ts
        join public.gateway_devices d on d.id = ts.device_id
        where ts.started_at >= now() - range_interval
    ), '[]'::jsonb);
end;
$$;

create or replace function public.get_tracking_metrics(p_session_id uuid)
returns table(
    recorded_at timestamptz,
    heart_rate_bpm double precision,
    speed_mps double precision,
    pace_seconds_per_km double precision,
    cadence_spm double precision,
    elevation_m double precision,
    distance_m double precision,
    steps bigint,
    calories_kcal double precision
)
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
    bucket_interval interval;
begin
    if not exists (select 1 from public.tracking_sessions ts where ts.id = p_session_id) then
        raise exception 'Tracking session not found or not authorized' using errcode = '42501';
    end if;
    select make_interval(secs => greatest(5, ceil(extract(epoch from (coalesce(ts.ended_at, now()) - ts.started_at)) / 600)::integer))
    into bucket_interval from public.tracking_sessions ts where ts.id = p_session_id;

    return query
    select distinct on (date_bin(bucket_interval, m.recorded_at, timestamptz '2001-01-01'))
        m.recorded_at, m.heart_rate_bpm, m.speed_mps, m.pace_seconds_per_km,
        m.cadence_spm, m.elevation_m, m.distance_m, m.steps, m.calories_kcal
    from public.tracking_metric_samples m
    where m.session_id = p_session_id
    order by date_bin(bucket_interval, m.recorded_at, timestamptz '2001-01-01'), m.recorded_at desc;
end;
$$;

revoke all on public.tracking_sessions, public.tracking_metric_samples from anon, authenticated;
grant select on public.tracking_sessions, public.tracking_metric_samples to authenticated;

revoke all on function public.register_location_tracker(text) from public, anon;
revoke all on function public.ingest_location_tracker_batch(jsonb, jsonb, jsonb) from public, anon;
revoke all on function public.location_history_for_device(uuid, timestamptz, double precision) from public, anon;
revoke all on function public.get_tracking_sessions(text) from public, anon;
revoke all on function public.get_tracking_metrics(uuid) from public, anon;
grant execute on function public.register_location_tracker(text) to authenticated;
grant execute on function public.ingest_location_tracker_batch(jsonb, jsonb, jsonb) to authenticated;
grant execute on function public.location_history_for_device(uuid, timestamptz, double precision) to authenticated;
grant execute on function public.get_tracking_sessions(text) to authenticated;
grant execute on function public.get_tracking_metrics(uuid) to authenticated;

commit;
