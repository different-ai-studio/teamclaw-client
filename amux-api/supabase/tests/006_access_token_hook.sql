begin;

select plan(7);

-- Rule catalog for a member yields exactly 8 allow rules with the expected topic shapes.
select is(
  (select count(*)::int
     from public.amux_acl_rules_for(
       '11111111-1111-1111-1111-111111111111'::uuid,
       '22222222-2222-2222-2222-222222222222'::uuid,
       'member'
     )),
  8,
  'member rule set has exactly 8 rules'
);

select bag_eq(
  $$select action, topic from public.amux_acl_rules_for(
      '11111111-1111-1111-1111-111111111111'::uuid,
      '22222222-2222-2222-2222-222222222222'::uuid,
      'member')$$,
  $$values
      ('sub','amux/11111111-1111-1111-1111-111111111111/user/22222222-2222-2222-2222-222222222222/notify'),
      ('sub','amux/11111111-1111-1111-1111-111111111111/session/+/live'),
      ('sub','amux/11111111-1111-1111-1111-111111111111/device/+/state'),
      ('sub','amux/11111111-1111-1111-1111-111111111111/device/+/runtime/+/state'),
      ('sub','amux/11111111-1111-1111-1111-111111111111/device/+/runtime/+/events'),
      ('sub','amux/11111111-1111-1111-1111-111111111111/device/+/rpc/res'),
      ('pub','amux/11111111-1111-1111-1111-111111111111/device/+/rpc/req'),
      ('pub','amux/11111111-1111-1111-1111-111111111111/device/+/runtime/+/commands')
  $$,
  'member rule topics match exactly'
);

-- Unknown actor_type yields zero rows (no exception).
select is(
  (select count(*)::int
     from public.amux_acl_rules_for(
       gen_random_uuid(), gen_random_uuid(), 'bogus'
     )),
  0,
  'unknown actor_type yields zero rules'
);

-- Rule catalog for an agent yields exactly 12 allow rules.
select is(
  (select count(*)::int
     from public.amux_acl_rules_for(
       '33333333-3333-3333-3333-333333333333'::uuid,
       '44444444-4444-4444-4444-444444444444'::uuid,
       'agent'
     )),
  12,
  'agent rule set has exactly 12 rules'
);

select bag_eq(
  $$select action, topic from public.amux_acl_rules_for(
      '33333333-3333-3333-3333-333333333333'::uuid,
      '44444444-4444-4444-4444-444444444444'::uuid,
      'agent')$$,
  $$values
      ('pub','amux/33333333-3333-3333-3333-333333333333/device/44444444-4444-4444-4444-444444444444/state'),
      ('pub','amux/33333333-3333-3333-3333-333333333333/device/44444444-4444-4444-4444-444444444444/runtime/+/state'),
      ('pub','amux/33333333-3333-3333-3333-333333333333/device/44444444-4444-4444-4444-444444444444/runtime/+/events'),
      ('pub','amux/33333333-3333-3333-3333-333333333333/device/44444444-4444-4444-4444-444444444444/notify'),
      ('pub','amux/33333333-3333-3333-3333-333333333333/device/+/rpc/res'),
      ('pub','amux/33333333-3333-3333-3333-333333333333/session/+/live'),
      ('pub','amux/33333333-3333-3333-3333-333333333333/user/+/notify'),
      ('sub','amux/33333333-3333-3333-3333-333333333333/device/44444444-4444-4444-4444-444444444444/runtime/+/commands'),
      ('sub','amux/33333333-3333-3333-3333-333333333333/device/44444444-4444-4444-4444-444444444444/rpc/req'),
      ('sub','amux/33333333-3333-3333-3333-333333333333/device/44444444-4444-4444-4444-444444444444/notify'),
      ('sub','amux/33333333-3333-3333-3333-333333333333/session/+/live'),
      ('sub','amux/33333333-3333-3333-3333-333333333333/user/44444444-4444-4444-4444-444444444444/notify')
  $$,
  'agent rule topics match exactly'
);

-- Agents do not get the member-only "publish commands" permission.
select is(
  (select count(*)::int
     from public.amux_acl_rules_for(
       gen_random_uuid(),
       gen_random_uuid(),
       'agent')
    where topic like '%runtime/+/commands' and action = 'pub'),
  0,
  'agent rule set does not include pub device/+/runtime/+/commands'
);

-- Hook called with null user_id (anon/service_role) must return event unchanged.
select is(
  public.amux_access_token_hook(
    jsonb_build_object(
      'user_id', null,
      'claims',  jsonb_build_object('sub','anon','role','anon','aud','anon')
    )
  ),
  jsonb_build_object(
    'user_id', null,
    'claims',  jsonb_build_object('sub','anon','role','anon','aud','anon')
  ),
  'hook with null user_id returns event unchanged'
);

select * from finish();
rollback;
