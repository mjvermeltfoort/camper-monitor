begin;
select plan(12);

select has_column('public', 'gateway_devices', 'device_kind', 'devices identify their kind');
select has_column('public', 'location_readings', 'session_id', 'locations can belong to a session');
select has_table('public', 'tracking_sessions', 'tracking sessions table exists');
select has_table('public', 'tracking_metric_samples', 'tracking metrics table exists');
select ok(not has_table_privilege('authenticated', 'public.tracking_sessions', 'insert'), 'trackers cannot insert sessions directly');
select ok(not has_table_privilege('authenticated', 'public.tracking_metric_samples', 'insert'), 'trackers cannot insert metrics directly');
select ok(has_function_privilege('authenticated', 'public.register_location_tracker(text)', 'execute'), 'authenticated tracker can register');
select ok(has_function_privilege('authenticated', 'public.ingest_location_tracker_batch(jsonb,jsonb,jsonb)', 'execute'), 'authenticated tracker can ingest');
select ok(not has_function_privilege('anon', 'public.ingest_location_tracker_batch(jsonb,jsonb,jsonb)', 'execute'), 'unauthenticated client cannot ingest');

select set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'role', 'authenticated', 'is_anonymous', true)::text, true);
select throws_ok(
    $$select public.ingest_location_tracker_batch(
        jsonb_build_object('id', gen_random_uuid(), 'started_at', now(), 'latest_sample_at', now()),
        '[]'::jsonb,
        '[]'::jsonb
    )$$,
    '42501', 'tracker missing or disabled', 'ingest requires registered enabled tracker'
);
select throws_ok(
    $$select public.ingest_location_tracker_batch(
        '{}'::jsonb,
        (select jsonb_agg(value) from generate_series(1, 101) value),
        '[]'::jsonb
    )$$,
    '22023', null, 'location batch over 100 rejected'
);
select throws_ok(
    $$select public.ingest_location_tracker_batch(
        '{}'::jsonb,
        '[]'::jsonb,
        (select jsonb_agg(value) from generate_series(1, 101) value)
    )$$,
    '22023', null, 'metric batch over 100 rejected'
);

select * from finish();
rollback;
