create or replace function app.current_member_id()
returns uuid
language sql
stable
security definer
set search_path = public, auth
as $$
  select m.id
  from public.members m
  where m.user_id = auth.uid()
$$;

create or replace function app.is_team_member(target_team_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, auth
as $$
  select exists (
    select 1
    from public.team_members tm
    where tm.team_id = target_team_id
      and tm.member_id = app.current_member_id()
  )
$$;

create or replace function app.current_team_role(target_team_id uuid)
returns text
language sql
stable
security definer
set search_path = public, auth
as $$
  select tm.role
  from public.team_members tm
  where tm.team_id = target_team_id
    and tm.member_id = app.current_member_id()
  limit 1
$$;

create or replace function app.is_session_participant(target_session_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, auth
as $$
  select exists (
    select 1
    from public.session_participants sp
    where sp.session_id = target_session_id
      and sp.actor_id = app.current_member_id()
  )
$$;

create or replace function app.can_prompt_agent(target_agent_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, auth
as $$
  select exists (
    select 1
    from public.agent_member_access ama
    where ama.agent_id = target_agent_id
      and ama.member_id = app.current_member_id()
      and ama.permission_level in ('prompt', 'admin')
  )
  or exists (
    select 1
    from public.agents a
    join public.actors act on act.id = a.id
    where a.id = target_agent_id
      and app.current_team_role(act.team_id) in ('owner', 'admin')
  )
$$;

alter table public.teams enable row level security;
alter table public.actors enable row level security;
alter table public.members enable row level security;
alter table public.team_members enable row level security;
alter table public.workspaces enable row level security;
alter table public.agents enable row level security;
alter table public.agent_member_access enable row level security;
alter table public.tasks enable row level security;
alter table public.task_external_refs enable row level security;
alter table public.sessions enable row level security;
alter table public.session_participants enable row level security;
alter table public.messages enable row level security;
alter table public.agent_runtimes enable row level security;

create policy teams_select_if_member on public.teams
for select using (app.is_team_member(id));

create policy actors_select_if_team_member on public.actors
for select using (app.is_team_member(team_id));

create policy members_select_self_or_team_member on public.members
for select using (
  id = app.current_member_id()
  or exists (
    select 1
    from public.actors a
    where a.id = members.id
      and app.is_team_member(a.team_id)
  )
);

create policy team_members_select_if_team_member on public.team_members
for select using (app.is_team_member(team_id));

create policy workspaces_select_if_team_member on public.workspaces
for select using (app.is_team_member(team_id));

create policy workspaces_insert_if_team_member on public.workspaces
for insert with check (app.is_team_member(team_id));

create policy workspaces_update_if_team_member on public.workspaces
for update using (app.is_team_member(team_id))
with check (app.is_team_member(team_id));

create policy agents_select_if_team_member on public.agents
for select using (
  exists (
    select 1
    from public.actors a
    where a.id = agents.id
      and app.is_team_member(a.team_id)
  )
);

create policy agent_member_access_select_if_team_member on public.agent_member_access
for select using (
  exists (
    select 1
    from public.agents a
    join public.actors act on act.id = a.id
    where a.id = agent_member_access.agent_id
      and app.is_team_member(act.team_id)
  )
);

create policy agent_member_access_manage_if_admin on public.agent_member_access
for all using (
  exists (
    select 1
    from public.agents a
    join public.actors act on act.id = a.id
    where a.id = agent_member_access.agent_id
      and app.current_team_role(act.team_id) in ('owner', 'admin')
  )
)
with check (
  exists (
    select 1
    from public.agents a
    join public.actors act on act.id = a.id
    where a.id = agent_member_access.agent_id
      and app.current_team_role(act.team_id) in ('owner', 'admin')
  )
);

create policy tasks_select_if_team_member on public.tasks
for select using (app.is_team_member(team_id));

create policy tasks_insert_if_team_member on public.tasks
for insert with check (app.is_team_member(team_id));

create policy tasks_update_if_team_member on public.tasks
for update using (app.is_team_member(team_id))
with check (app.is_team_member(team_id));

create policy task_external_refs_select_if_team_member on public.task_external_refs
for select using (
  exists (
    select 1
    from public.tasks t
    where t.id = task_external_refs.task_id
      and app.is_team_member(t.team_id)
  )
);

create policy task_external_refs_insert_if_team_member on public.task_external_refs
for insert with check (
  exists (
    select 1
    from public.tasks t
    where t.id = task_external_refs.task_id
      and app.is_team_member(t.team_id)
  )
);

create policy sessions_select_if_team_member on public.sessions
for select using (app.is_team_member(team_id));

create policy sessions_insert_if_team_member on public.sessions
for insert with check (app.is_team_member(team_id));

create policy sessions_update_if_team_member on public.sessions
for update using (app.is_team_member(team_id))
with check (app.is_team_member(team_id));

create policy session_participants_select_if_team_member on public.session_participants
for select using (
  exists (
    select 1
    from public.sessions s
    where s.id = session_participants.session_id
      and app.is_team_member(s.team_id)
  )
);

create policy session_participants_insert_if_team_member on public.session_participants
for insert with check (
  exists (
    select 1
    from public.sessions s
    where s.id = session_participants.session_id
      and app.is_team_member(s.team_id)
  )
);

create policy messages_select_if_session_participant on public.messages
for select using (app.is_session_participant(session_id));

create policy messages_insert_if_session_participant on public.messages
for insert with check (app.is_session_participant(session_id));

create policy agent_runtimes_select_if_team_member on public.agent_runtimes
for select using (app.is_team_member(team_id));
