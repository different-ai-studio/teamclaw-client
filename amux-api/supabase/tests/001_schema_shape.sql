begin;
select plan(34);

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
select has_trigger('public', 'agents', 'enforce_agents_same_team');
select has_trigger('public', 'agent_member_access', 'enforce_agent_member_access_same_team');
select has_trigger('public', 'tasks', 'enforce_tasks_same_team');
select has_trigger('public', 'task_external_refs', 'enforce_task_external_refs_same_team');
select has_trigger('public', 'sessions', 'enforce_sessions_same_team');
select has_trigger('public', 'session_participants', 'enforce_session_participants_same_team');
select has_trigger('public', 'messages', 'enforce_messages_same_team');
select has_trigger('public', 'agent_runtimes', 'enforce_agent_runtimes_same_team');

select * from finish();
rollback;
