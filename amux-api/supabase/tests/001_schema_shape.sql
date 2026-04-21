begin;

create or replace function pg_temp.raises_sqlstate(p_sql text, p_expected_sqlstate text)
returns boolean
language plpgsql
as $$
declare
  v_sqlstate text;
begin
  execute p_sql;
  return false;
exception
  when others then
    get stacked diagnostics v_sqlstate = returned_sqlstate;
    return v_sqlstate = p_expected_sqlstate;
end;
$$;

select plan(43);

select has_schema('app');
select has_table('public', 'teams');
select has_table('public', 'actors');
select has_table('public', 'members');
select has_table('public', 'team_members');
select has_table('public', 'workspaces');
select has_table('public', 'agents');
select has_table('public', 'agent_member_access');
select has_table('public', 'tasks');
select has_table('public', 'task_external_refs');
select has_table('public', 'sessions');
select has_table('public', 'session_participants');
select has_table('public', 'messages');
select has_table('public', 'agent_runtimes');

select col_type_is('public', 'actors', 'last_active_at', 'timestamp with time zone');
select col_type_is('public', 'members', 'id', 'uuid');
select col_type_is('public', 'agents', 'id', 'uuid');

select fk_ok('public', 'members', 'id', 'public', 'actors', 'id');
select fk_ok('public', 'agents', 'id', 'public', 'actors', 'id');
select fk_ok('public', 'sessions', 'task_id', 'public', 'tasks', 'id');
select fk_ok('public', 'messages', 'session_id', 'public', 'sessions', 'id');
select fk_ok('public', 'agent_runtimes', 'agent_id', 'public', 'agents', 'id');

select has_trigger('public', 'members', 'enforce_members_actor_type');
select has_trigger('public', 'agents', 'enforce_agents_actor_type');
select has_trigger('public', 'team_members', 'enforce_team_members_same_team');
select has_trigger('public', 'workspaces', 'enforce_workspaces_same_team');
select has_trigger('public', 'actors', 'enforce_actors_parent_integrity');
select has_trigger('public', 'agents', 'enforce_agents_same_team');
select has_trigger('public', 'agent_member_access', 'enforce_agent_member_access_same_team');
select has_trigger('public', 'tasks', 'enforce_tasks_same_team');
select has_trigger('public', 'workspaces', 'enforce_workspaces_parent_integrity');
select has_trigger('public', 'task_external_refs', 'enforce_task_external_refs_same_team');
select has_trigger('public', 'sessions', 'enforce_sessions_same_team');
select has_trigger('public', 'tasks', 'enforce_tasks_parent_integrity');
select has_trigger('public', 'session_participants', 'enforce_session_participants_same_team');
select has_trigger('public', 'messages', 'enforce_messages_same_team');
select has_trigger('public', 'sessions', 'enforce_sessions_parent_integrity');
select has_trigger('public', 'agent_runtimes', 'enforce_agent_runtimes_same_team');

insert into public.teams (id, slug, name)
values
  ('00000000-0000-0000-0000-000000000001', 'team-one', 'Team One'),
  ('00000000-0000-0000-0000-000000000002', 'team-two', 'Team Two');

insert into public.actors (id, team_id, actor_type, display_name)
values
  ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001', 'member', 'Subtype Member'),
  ('10000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000001', 'member', 'Scoped Member');

insert into public.members (id, status)
values
  ('10000000-0000-0000-0000-000000000001', 'active'),
  ('10000000-0000-0000-0000-000000000002', 'active');

insert into public.team_members (id, team_id, member_id, role)
values (
  '20000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-000000000001',
  '10000000-0000-0000-0000-000000000002',
  'member'
);

insert into public.workspaces (id, team_id, created_by_member_id, name)
values (
  '30000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-000000000001',
  '10000000-0000-0000-0000-000000000002',
  'Workspace One'
);

insert into public.tasks (id, team_id, workspace_id, created_by_actor_id, title, status)
values (
  '40000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-000000000001',
  '30000000-0000-0000-0000-000000000001',
  '10000000-0000-0000-0000-000000000002',
  'Task One',
  'open'
);

insert into public.sessions (id, team_id, task_id, created_by_actor_id, mode, title)
values (
  '50000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-000000000001',
  '40000000-0000-0000-0000-000000000001',
  '10000000-0000-0000-0000-000000000002',
  'solo',
  'Session One'
);

insert into public.messages (id, team_id, session_id, sender_actor_id, kind, content)
values (
  '60000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-000000000001',
  '50000000-0000-0000-0000-000000000001',
  '10000000-0000-0000-0000-000000000002',
  'text',
  'Hello'
);

select ok(
  pg_temp.raises_sqlstate(
    $sql$update public.actors
          set actor_type = 'agent'
          where id = '10000000-0000-0000-0000-000000000001'$sql$,
    '23514'
  ),
  'actors.actor_type update is rejected when a members row exists'
);

select ok(
  pg_temp.raises_sqlstate(
    $sql$update public.actors
          set team_id = '00000000-0000-0000-0000-000000000002'
          where id = '10000000-0000-0000-0000-000000000002'$sql$,
    '23514'
  ),
  'actors.team_id update is rejected when dependents exist'
);

select ok(
  pg_temp.raises_sqlstate(
    $sql$update public.workspaces
          set team_id = '00000000-0000-0000-0000-000000000002'
          where id = '30000000-0000-0000-0000-000000000001'$sql$,
    '23514'
  ),
  'workspaces.team_id update is rejected when dependent tasks exist'
);

select ok(
  pg_temp.raises_sqlstate(
    $sql$update public.tasks
          set team_id = '00000000-0000-0000-0000-000000000002'
          where id = '40000000-0000-0000-0000-000000000001'$sql$,
    '23514'
  ),
  'tasks.team_id update is rejected when dependent sessions exist'
);

select ok(
  pg_temp.raises_sqlstate(
    $sql$update public.sessions
          set team_id = '00000000-0000-0000-0000-000000000002'
          where id = '50000000-0000-0000-0000-000000000001'$sql$,
    '23514'
  ),
  'sessions.team_id update is rejected when dependent messages exist'
);

select * from finish();
rollback;
