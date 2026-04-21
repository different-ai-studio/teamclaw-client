begin;
select plan(22);

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

select * from finish();
rollback;
