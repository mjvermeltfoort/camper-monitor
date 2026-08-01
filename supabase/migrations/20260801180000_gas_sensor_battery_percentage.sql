begin;

-- Mopeka Pro Check CR2032 scale: 2.20 V is empty and 2.85 V is full.
create function public.fill_gas_sensor_battery_percentage()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
    if new.sensor_battery_pct is null and new.sensor_battery_v is not null then
        new.sensor_battery_pct := round(
            least(
                100::numeric,
                greatest(
                    0::numeric,
                    ((new.sensor_battery_v::numeric - 2.2::numeric)
                        / 0.65::numeric) * 100::numeric
                )
            ),
            2
        );
    end if;

    return new;
end;
$$;

revoke all on function public.fill_gas_sensor_battery_percentage()
    from public, anon, authenticated;

update public.gas_readings
set sensor_battery_pct = round(
    least(
        100::numeric,
        greatest(
            0::numeric,
            ((sensor_battery_v::numeric - 2.2::numeric)
                / 0.65::numeric) * 100::numeric
        )
    ),
    2
)
where sensor_battery_pct is null
  and sensor_battery_v is not null;

drop trigger if exists gas_readings_fill_sensor_battery_percentage
    on public.gas_readings;

create trigger gas_readings_fill_sensor_battery_percentage
before insert or update of sensor_battery_v, sensor_battery_pct
on public.gas_readings
for each row
when (new.sensor_battery_pct is null and new.sensor_battery_v is not null)
execute function public.fill_gas_sensor_battery_percentage();

commit;
