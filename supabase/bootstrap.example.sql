-- Run this only after replacing the UUIDs below with users from
-- Supabase > Authentication > Users. The viewer signs in with Google; the
-- gateway uses its own email/password Auth user.
begin;

insert into public.camper (name, vehicle_model)
values ('Mijn camper', 'Mercedes Sprinter');

insert into public.authorized_viewers (user_id, role)
values ('00000000-0000-0000-0000-000000000001', 'owner');

insert into public.gateway_devices (id, auth_user_id, name)
values (
  '00000000-0000-0000-0000-000000000010',
  '00000000-0000-0000-0000-000000000002',
  'Campertelefoon'
);

commit;

