begin;
select plan(8);

select lives_ok(
$$
  select app.current_member_id();
$$,
'helper function exists'
);

select lives_ok(
$$
  select app.is_team_member(gen_random_uuid());
$$,
'team membership helper exists'
);

select lives_ok(
$$
  select app.can_prompt_agent(gen_random_uuid());
$$,
'agent prompt helper exists'
);

select policies_are('public', 'teams', array[
  'teams_select_if_member'
]);

select policies_are('public', 'sessions', array[
  'sessions_select_if_team_member',
  'sessions_insert_if_team_member',
  'sessions_update_if_team_member'
]);

select policies_are('public', 'messages', array[
  'messages_select_if_session_participant',
  'messages_insert_if_session_participant'
]);

select policies_are('public', 'agent_member_access', array[
  'agent_member_access_select_if_team_member',
  'agent_member_access_manage_if_admin'
]);

select policies_are('public', 'agent_runtimes', array[
  'agent_runtimes_select_if_team_member'
]);

select * from finish();
rollback;
