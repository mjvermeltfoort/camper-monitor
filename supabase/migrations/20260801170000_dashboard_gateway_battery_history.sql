begin;

drop function if exists public.get_dashboard_history(text);

create function public.get_dashboard_history(p_range text)
returns table (
    bucket_at timestamptz,
    battery_soc_pct numeric,
    gas_fill_pct numeric,
    battery_voltage_v numeric,
    average_power_w numeric,
    gateway_battery_pct numeric
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
        select
            date_bin(bucket_interval, b.recorded_at, timestamptz '2001-01-01') as bucket,
            ((array_agg(b.soc_pct order by b.recorded_at desc)
                filter (where b.soc_pct is not null))[1])::numeric as soc_pct,
            (avg(b.voltage_v) filter (where b.voltage_v is not null))::numeric as voltage_v,
            (avg(b.power_w) filter (where b.power_w is not null))::numeric as power_w
        from public.battery_readings b
        where b.recorded_at >= now() - range_interval
        group by date_bin(bucket_interval, b.recorded_at, timestamptz '2001-01-01')
    ), gas as (
        select
            date_bin(bucket_interval, g.recorded_at, timestamptz '2001-01-01') as bucket,
            ((array_agg(g.fill_pct order by g.recorded_at desc)
                filter (where g.fill_pct is not null))[1])::numeric as fill_pct
        from public.gas_readings g
        where g.recorded_at >= now() - range_interval
        group by date_bin(bucket_interval, g.recorded_at, timestamptz '2001-01-01')
    ), gateway as (
        select
            date_bin(bucket_interval, gr.recorded_at, timestamptz '2001-01-01') as bucket,
            ((array_agg(gr.phone_battery_pct order by gr.recorded_at desc)
                filter (where gr.phone_battery_pct is not null))[1])::numeric as battery_pct
        from public.gateway_readings gr
        where gr.recorded_at >= now() - range_interval
        group by date_bin(bucket_interval, gr.recorded_at, timestamptz '2001-01-01')
    )
    select
        coalesce(battery.bucket, gas.bucket, gateway.bucket),
        battery.soc_pct,
        gas.fill_pct,
        battery.voltage_v,
        battery.power_w,
        gateway.battery_pct
    from battery
    full join gas on gas.bucket = battery.bucket
    full join gateway on gateway.bucket = coalesce(battery.bucket, gas.bucket)
    order by coalesce(battery.bucket, gas.bucket, gateway.bucket);
end;
$$;

grant usage on schema public to authenticated;
grant select on public.authorized_viewers, public.camper, public.gateway_devices,
    public.battery_readings, public.gas_readings, public.gateway_readings,
    public.location_readings to authenticated;

revoke all on function public.get_dashboard_history(text) from public, anon;
grant execute on function public.get_dashboard_history(text) to authenticated;

commit;
