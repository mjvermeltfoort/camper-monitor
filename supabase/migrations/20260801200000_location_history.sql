begin;

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
    sample record;
    previous_seen_at timestamptz;
    anchor_at timestamptz;
    anchor_latitude double precision;
    anchor_longitude double precision;
    anchor_accuracy_m double precision;
    elapsed_seconds double precision;
    haversine_a double precision;
    leg_distance_m double precision;
    total_distance_m double precision := 0;
    segment_point_count integer := 0;
    segment_points jsonb := '[]'::jsonb;
    raw_segments jsonb := '[]'::jsonb;
    downsample_seconds double precision;
    route_segments jsonb;
begin
    if p_range = '24h' then
        range_interval := interval '24 hours';
    elsif p_range = '7d' then
        range_interval := interval '7 days';
    elsif p_range = '30d' then
        range_interval := interval '30 days';
    else
        raise exception 'Unsupported location range: %', p_range using errcode = '22023';
    end if;

    if not exists (select 1 from public.camper c where c.singleton) then
        raise exception 'No camper access is assigned to this user' using errcode = '42501';
    end if;

    range_started_at := now() - range_interval;

    for sample in
        with eligible as (
            select
                l.id,
                l.recorded_at,
                l.latitude,
                l.longitude,
                l.accuracy_m,
                row_number() over (
                    partition by date_bin(
                        interval '10 seconds',
                        l.recorded_at,
                        timestamptz '2001-01-01 00:00:00+00'
                    )
                    order by l.accuracy_m asc nulls last, l.recorded_at desc, l.id
                ) as accuracy_rank
            from public.location_readings l
            where l.recorded_at >= range_started_at
              and l.recorded_at <= now()
              and (l.accuracy_m is null or l.accuracy_m <= 100)
        )
        select recorded_at, latitude, longitude, accuracy_m
        from eligible
        where accuracy_rank = 1
        order by recorded_at, id
    loop
        if anchor_at is null then
            anchor_at := sample.recorded_at;
            previous_seen_at := sample.recorded_at;
            anchor_latitude := sample.latitude;
            anchor_longitude := sample.longitude;
            anchor_accuracy_m := sample.accuracy_m;
            segment_points := jsonb_build_array(jsonb_build_object(
                'recorded_at', extract(epoch from sample.recorded_at),
                'coordinates', jsonb_build_array(sample.longitude, sample.latitude)
            ));
            segment_point_count := 1;
            continue;
        end if;

        if sample.recorded_at - previous_seen_at > interval '30 minutes' then
            if segment_point_count >= 2 then
                raw_segments := raw_segments || jsonb_build_array(segment_points);
            end if;

            anchor_at := sample.recorded_at;
            previous_seen_at := sample.recorded_at;
            anchor_latitude := sample.latitude;
            anchor_longitude := sample.longitude;
            anchor_accuracy_m := sample.accuracy_m;
            segment_points := jsonb_build_array(jsonb_build_object(
                'recorded_at', extract(epoch from sample.recorded_at),
                'coordinates', jsonb_build_array(sample.longitude, sample.latitude)
            ));
            segment_point_count := 1;
            continue;
        end if;

        previous_seen_at := sample.recorded_at;
        haversine_a :=
            power(sin(radians(sample.latitude - anchor_latitude) / 2), 2)
            + cos(radians(anchor_latitude)) * cos(radians(sample.latitude))
            * power(sin(radians(sample.longitude - anchor_longitude) / 2), 2);
        leg_distance_m := 12742000 * asin(sqrt(least(1, greatest(0, haversine_a))));

        if leg_distance_m <= greatest(
            10,
            coalesce(anchor_accuracy_m, 0),
            coalesce(sample.accuracy_m, 0)
        ) then
            continue;
        end if;

        elapsed_seconds := extract(epoch from sample.recorded_at - anchor_at);
        if elapsed_seconds <= 0 or leg_distance_m / elapsed_seconds * 3.6 > 180 then
            if segment_point_count >= 2 then
                raw_segments := raw_segments || jsonb_build_array(segment_points);
            end if;

            anchor_at := sample.recorded_at;
            anchor_latitude := sample.latitude;
            anchor_longitude := sample.longitude;
            anchor_accuracy_m := sample.accuracy_m;
            segment_points := jsonb_build_array(jsonb_build_object(
                'recorded_at', extract(epoch from sample.recorded_at),
                'coordinates', jsonb_build_array(sample.longitude, sample.latitude)
            ));
            segment_point_count := 1;
            continue;
        end if;

        total_distance_m := total_distance_m + leg_distance_m;
        segment_points := segment_points || jsonb_build_array(jsonb_build_object(
            'recorded_at', extract(epoch from sample.recorded_at),
            'coordinates', jsonb_build_array(sample.longitude, sample.latitude)
        ));
        segment_point_count := segment_point_count + 1;
        anchor_at := sample.recorded_at;
        anchor_latitude := sample.latitude;
        anchor_longitude := sample.longitude;
        anchor_accuracy_m := sample.accuracy_m;
    end loop;

    if segment_point_count >= 2 then
        raw_segments := raw_segments || jsonb_build_array(segment_points);
    end if;

    downsample_seconds := greatest(1, extract(epoch from range_interval) / 2498);

    with point_rows as (
        select
            segment.ordinality as segment_number,
            point.ordinality as point_number,
            count(*) over (partition by segment.ordinality) as point_count,
            (point.value -> 'coordinates') as coordinates,
            floor(
                ((point.value ->> 'recorded_at')::double precision
                    - extract(epoch from range_started_at)) / downsample_seconds
            )::bigint as time_bucket
        from jsonb_array_elements(raw_segments) with ordinality as segment(value, ordinality)
        cross join lateral jsonb_array_elements(segment.value)
            with ordinality as point(value, ordinality)
    ), ranked_points as (
        select
            point_rows.*,
            row_number() over (
                partition by segment_number, time_bucket
                order by point_number
            ) as bucket_rank
        from point_rows
    ), sampled_segments as (
        select
            segment_number,
            jsonb_agg(coordinates order by point_number) as coordinates
        from ranked_points
        where point_number = 1
           or point_number = point_count
           or bucket_rank = 1
        group by segment_number
        having count(*) >= 2
    )
    select coalesce(jsonb_agg(coordinates order by segment_number), '[]'::jsonb)
    into route_segments
    from sampled_segments;

    return jsonb_build_object(
        'range', p_range,
        'distance_km', total_distance_m / 1000,
        'route_segments', route_segments
    );
end;
$$;

revoke all on function public.get_location_history(text) from public, anon;
grant execute on function public.get_location_history(text) to authenticated;

commit;
