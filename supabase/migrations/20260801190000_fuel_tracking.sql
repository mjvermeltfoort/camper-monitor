begin;

alter table public.camper
    add column fuel_tank_capacity_l numeric(6,2) not null default 70
        check (fuel_tank_capacity_l > 0),
    add column fuel_tracking_start_odometer_km integer not null default 248654
        check (fuel_tracking_start_odometer_km >= 0),
    add column fuel_tracking_start_is_full boolean not null default false;

create table public.fuel_fillups (
    id uuid primary key default gen_random_uuid(),
    camper_id uuid not null references public.camper(id) on delete cascade,
    odometer_km integer not null check (odometer_km >= 0),
    liters numeric(6,2) not null check (liters > 0),
    amount numeric(12,2) not null check (amount > 0),
    currency text not null check (currency ~ '^[A-Z]{3}$'),
    exchange_rate_to_eur numeric(20,10) not null check (exchange_rate_to_eur > 0),
    exchange_rate_date date not null,
    amount_eur numeric(12,2) not null check (amount_eur > 0),
    exchange_rate_source text not null,
    is_full boolean not null default true,
    recorded_at timestamptz not null default now(),
    created_by uuid not null references auth.users(id) on delete restrict,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    unique (camper_id, odometer_km),
    constraint fuel_fillups_conversion_check
        check (amount_eur = round(amount * exchange_rate_to_eur, 2)),
    constraint fuel_fillups_exchange_source_check check (
        (currency = 'EUR'
            and exchange_rate_to_eur = 1
            and amount_eur = amount
            and exchange_rate_source = 'EUR')
        or
        (currency <> 'EUR' and exchange_rate_source = 'ECB via Frankfurter')
    )
);

create index fuel_fillups_camper_odometer_idx
    on public.fuel_fillups (camper_id, odometer_km desc);

create trigger fuel_fillups_set_updated_at
before update on public.fuel_fillups
for each row execute function public.set_camper_updated_at();

alter table public.fuel_fillups enable row level security;

create policy "authorized viewers can read fuel fillups"
on public.fuel_fillups for select to authenticated
using (exists (
    select 1
    from public.authorized_viewers v
    where v.user_id = (select auth.uid())
));

create function public.get_fuel_dashboard()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
    result jsonb;
begin
    if not exists (
        select 1
        from public.authorized_viewers v
        where v.user_id = (select auth.uid())
    ) then
        raise exception 'No camper access is assigned to this user'
            using errcode = '42501';
    end if;

    with camper_settings as (
        select
            c.id,
            c.fuel_tank_capacity_l,
            c.fuel_tracking_start_odometer_km,
            c.fuel_tracking_start_is_full
        from public.camper c
        where c.singleton
    ), fillups_with_anchor as (
        select
            f.*,
            coalesce(
                (
                    select max(previous.odometer_km)
                    from public.fuel_fillups previous
                    where previous.camper_id = f.camper_id
                      and previous.is_full
                      and previous.odometer_km < f.odometer_km
                ),
                case
                    when settings.fuel_tracking_start_is_full
                    then settings.fuel_tracking_start_odometer_km
                end
            ) as previous_full_odometer_km
        from public.fuel_fillups f
        join camper_settings settings on settings.id = f.camper_id
    ), calculated as (
        select
            f.*,
            case
                when f.is_full and f.previous_full_odometer_km is not null
                then f.odometer_km - f.previous_full_odometer_km
            end as distance_km,
            case
                when f.is_full and f.previous_full_odometer_km is not null
                then (
                    select sum(segment.liters)
                    from public.fuel_fillups segment
                    where segment.camper_id = f.camper_id
                      and segment.odometer_km > f.previous_full_odometer_km
                      and segment.odometer_km <= f.odometer_km
                )
            end as segment_liters
        from fillups_with_anchor f
    ), segments as (
        select
            c.*,
            round((c.segment_liters / nullif(c.distance_km, 0)) * 100, 2)
                as consumption_l_per_100km,
            round(c.amount_eur / c.liters, 3) as euro_per_liter
        from calculated c
    ), summary as (
        select
            (array_agg(s.consumption_l_per_100km order by s.odometer_km desc)
                filter (where s.consumption_l_per_100km is not null))[1]
                as latest_consumption_l_per_100km,
            round(
                (sum(s.segment_liters) filter (where s.distance_km > 0)
                    / nullif(sum(s.distance_km) filter (where s.distance_km > 0), 0)) * 100,
                2
            ) as average_consumption_l_per_100km,
            round(sum(s.amount_eur), 2) as total_spend_eur,
            round(sum(s.amount_eur) / nullif(sum(s.liters), 0), 3)
                as average_price_per_liter_eur,
            count(*) as costed_fillup_count
        from segments s
    )
    select jsonb_build_object(
        'tank_capacity_l', settings.fuel_tank_capacity_l,
        'tracking_start_odometer_km', settings.fuel_tracking_start_odometer_km,
        'tracking_start_is_full', settings.fuel_tracking_start_is_full,
        'can_manage', exists (
            select 1
            from public.authorized_viewers owner_access
            where owner_access.user_id = (select auth.uid())
              and owner_access.role = 'owner'
        ),
        'current_odometer_km', greatest(
            settings.fuel_tracking_start_odometer_km,
            coalesce((select max(s.odometer_km) from segments s), 0)
        ),
        'latest_consumption_l_per_100km', summary.latest_consumption_l_per_100km,
        'average_consumption_l_per_100km', summary.average_consumption_l_per_100km,
        'total_spend_eur', summary.total_spend_eur,
        'average_price_per_liter_eur', summary.average_price_per_liter_eur,
        'costed_fillup_count', summary.costed_fillup_count,
        'full_tank_range_km', round(
            settings.fuel_tank_capacity_l
                / nullif(summary.average_consumption_l_per_100km, 0) * 100,
            0
        ),
        'fillups', coalesce((
            select jsonb_agg(
                jsonb_build_object(
                    'id', s.id,
                    'odometer_km', s.odometer_km,
                    'liters', s.liters,
                    'amount', s.amount,
                    'currency', s.currency,
                    'exchange_rate_to_eur', s.exchange_rate_to_eur,
                    'exchange_rate_date', s.exchange_rate_date,
                    'exchange_rate_source', s.exchange_rate_source,
                    'amount_eur', s.amount_eur,
                    'euro_per_liter', s.euro_per_liter,
                    'is_full', s.is_full,
                    'recorded_at', s.recorded_at,
                    'distance_km', s.distance_km,
                    'segment_liters', s.segment_liters,
                    'consumption_l_per_100km', s.consumption_l_per_100km
                ) order by s.odometer_km desc
            )
            from segments s
        ), '[]'::jsonb)
    ) into result
    from camper_settings settings
    cross join summary;

    if result is null then
        raise exception 'No camper is configured' using errcode = '42501';
    end if;

    return result;
end;
$$;

create function public.save_fuel_fillup(
    p_odometer_km integer,
    p_liters numeric,
    p_is_full boolean,
    p_amount numeric,
    p_currency text,
    p_exchange_rate_to_eur numeric,
    p_exchange_rate_date date,
    p_amount_eur numeric,
    p_fillup_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    caller uuid := auth.uid();
    camper_record public.camper%rowtype;
    saved_id uuid;
    previous_odometer integer;
begin
    if caller is null or not exists (
        select 1
        from public.authorized_viewers v
        where v.user_id = caller
          and v.role = 'owner'
    ) then
        raise exception 'Only the camper owner can manage fuel fillups'
            using errcode = '42501';
    end if;

    select c.* into camper_record
    from public.camper c
    where c.singleton;

    if camper_record.id is null then
        raise exception 'No camper is configured' using errcode = '42501';
    end if;
    if p_odometer_km is null
       or p_odometer_km <= camper_record.fuel_tracking_start_odometer_km then
        raise exception 'Odometer must be greater than the tracking start'
            using errcode = '22023';
    end if;
    if p_liters is null
       or p_liters <= 0
       or p_liters > camper_record.fuel_tank_capacity_l then
        raise exception 'Liters must be greater than zero and no more than tank capacity'
            using errcode = '22023';
    end if;
    if p_is_full is null then
        raise exception 'Full-tank status is required' using errcode = '22023';
    end if;
    if p_amount is null or p_amount <= 0 or p_amount <> round(p_amount, 2) then
        raise exception 'Amount must be positive and use at most two decimals'
            using errcode = '22023';
    end if;
    p_currency := upper(trim(p_currency));
    if p_currency is null or p_currency !~ '^[A-Z]{3}$' then
        raise exception 'A valid three-letter currency code is required'
            using errcode = '22023';
    end if;
    if p_exchange_rate_to_eur is null or p_exchange_rate_to_eur <= 0 then
        raise exception 'A positive EUR exchange rate is required'
            using errcode = '22023';
    end if;
    if p_exchange_rate_date is null or p_exchange_rate_date > current_date then
        raise exception 'A valid exchange-rate date is required'
            using errcode = '22023';
    end if;
    if p_amount_eur is null
       or p_amount_eur <= 0
       or p_amount_eur <> round(p_amount_eur, 2)
       or p_amount_eur <> round(p_amount * p_exchange_rate_to_eur, 2) then
        raise exception 'EUR amount does not match amount times exchange rate'
            using errcode = '22023';
    end if;
    if p_currency = 'EUR'
       and (p_exchange_rate_to_eur <> 1 or p_amount_eur <> p_amount) then
        raise exception 'EUR fillups must use an exchange rate of one'
            using errcode = '22023';
    end if;

    if p_fillup_id is null then
        select max(f.odometer_km) into previous_odometer
        from public.fuel_fillups f
        where f.camper_id = camper_record.id;

        if previous_odometer is not null and p_odometer_km <= previous_odometer then
            raise exception 'A new odometer reading must be higher than the latest fillup'
                using errcode = '22023';
        end if;

        insert into public.fuel_fillups (
            camper_id, odometer_km, liters, amount, currency,
            exchange_rate_to_eur, exchange_rate_date, amount_eur,
            exchange_rate_source, is_full, created_by
        ) values (
            camper_record.id, p_odometer_km, p_liters, p_amount, p_currency,
            p_exchange_rate_to_eur, p_exchange_rate_date, p_amount_eur,
            case when p_currency = 'EUR' then 'EUR' else 'ECB via Frankfurter' end,
            p_is_full, caller
        )
        returning id into saved_id;
    else
        update public.fuel_fillups f
        set odometer_km = p_odometer_km,
            liters = p_liters,
            amount = p_amount,
            currency = p_currency,
            exchange_rate_to_eur = p_exchange_rate_to_eur,
            exchange_rate_date = p_exchange_rate_date,
            amount_eur = p_amount_eur,
            exchange_rate_source = case
                when p_currency = 'EUR' then 'EUR'
                else 'ECB via Frankfurter'
            end,
            is_full = p_is_full
        where f.id = p_fillup_id
          and f.camper_id = camper_record.id
        returning f.id into saved_id;

        if saved_id is null then
            raise exception 'Fuel fillup not found' using errcode = 'P0002';
        end if;
    end if;

    return saved_id;
exception
    when unique_violation then
        raise exception 'A fuel fillup already exists for this odometer reading'
            using errcode = '23505';
end;
$$;

create function public.delete_fuel_fillup(p_fillup_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    caller uuid := auth.uid();
    deleted_count integer;
begin
    if caller is null or not exists (
        select 1
        from public.authorized_viewers v
        where v.user_id = caller
          and v.role = 'owner'
    ) then
        raise exception 'Only the camper owner can manage fuel fillups'
            using errcode = '42501';
    end if;

    delete from public.fuel_fillups f
    using public.camper c
    where f.id = p_fillup_id
      and f.camper_id = c.id
      and c.singleton;
    get diagnostics deleted_count = row_count;

    if deleted_count = 0 then
        raise exception 'Fuel fillup not found' using errcode = 'P0002';
    end if;
end;
$$;

revoke all on public.fuel_fillups from anon, authenticated;

revoke all on function public.get_fuel_dashboard() from public, anon;
revoke all on function public.save_fuel_fillup(
    integer, numeric, boolean, numeric, text, numeric, date, numeric, uuid
)
    from public, anon;
revoke all on function public.delete_fuel_fillup(uuid) from public, anon;

grant execute on function public.get_fuel_dashboard() to authenticated;
grant execute on function public.save_fuel_fillup(
    integer, numeric, boolean, numeric, text, numeric, date, numeric, uuid
)
    to authenticated;
grant execute on function public.delete_fuel_fillup(uuid) to authenticated;

commit;
