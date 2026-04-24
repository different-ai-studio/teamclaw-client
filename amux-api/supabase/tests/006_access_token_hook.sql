begin;

select plan(3);

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

select * from finish();
rollback;
