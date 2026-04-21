create table public.teams (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique,
  name text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.actors (
  id uuid primary key default gen_random_uuid(),
  team_id uuid not null references public.teams(id) on delete cascade,
  actor_type text not null check (actor_type in ('member', 'agent')),
  display_name text not null,
  last_active_at timestamptz null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.members (
  id uuid primary key references public.actors(id) on delete cascade,
  user_id uuid null references auth.users(id) on delete set null,
  status text not null check (status in ('invited', 'active', 'disabled')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id)
);

create table public.team_members (
  id uuid primary key default gen_random_uuid(),
  team_id uuid not null references public.teams(id) on delete cascade,
  member_id uuid not null references public.members(id) on delete cascade,
  role text not null check (role in ('owner', 'admin', 'member')),
  joined_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (team_id, member_id)
);

create table public.workspaces (
  id uuid primary key default gen_random_uuid(),
  team_id uuid not null references public.teams(id) on delete cascade,
  created_by_member_id uuid null references public.members(id) on delete set null,
  name text not null,
  path text null,
  archived boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (team_id, name)
);

create table public.agents (
  id uuid primary key references public.actors(id) on delete cascade,
  default_workspace_id uuid null references public.workspaces(id) on delete set null,
  created_by_member_id uuid null references public.members(id) on delete set null,
  agent_kind text not null,
  capabilities jsonb not null default '{}'::jsonb,
  status text not null check (status in ('active', 'disabled', 'archived')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.agent_member_access (
  id uuid primary key default gen_random_uuid(),
  agent_id uuid not null references public.agents(id) on delete cascade,
  member_id uuid not null references public.members(id) on delete cascade,
  permission_level text not null check (permission_level in ('view', 'prompt', 'admin')),
  granted_by_member_id uuid null references public.members(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (agent_id, member_id)
);

create table public.tasks (
  id uuid primary key default gen_random_uuid(),
  team_id uuid not null references public.teams(id) on delete cascade,
  workspace_id uuid null references public.workspaces(id) on delete set null,
  parent_task_id uuid null references public.tasks(id) on delete set null,
  created_by_actor_id uuid not null references public.actors(id) on delete restrict,
  title text not null,
  description text not null default '',
  status text not null check (status in ('open', 'in_progress', 'done')),
  archived boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.task_external_refs (
  id uuid primary key default gen_random_uuid(),
  task_id uuid not null references public.tasks(id) on delete cascade,
  provider text not null check (provider in ('github', 'linear', 'jira')),
  external_id text not null,
  external_key text null,
  external_url text not null,
  linked_by_actor_id uuid not null references public.actors(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (provider, external_id)
);

create table public.sessions (
  id uuid primary key default gen_random_uuid(),
  team_id uuid not null references public.teams(id) on delete cascade,
  task_id uuid not null references public.tasks(id) on delete cascade,
  created_by_actor_id uuid not null references public.actors(id) on delete restrict,
  primary_agent_id uuid null references public.agents(id) on delete set null,
  mode text not null check (mode in ('solo', 'collab', 'control')),
  title text not null,
  summary text not null default '',
  last_message_preview text null,
  last_message_at timestamptz null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.session_participants (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references public.sessions(id) on delete cascade,
  actor_id uuid not null references public.actors(id) on delete cascade,
  role text null,
  joined_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (session_id, actor_id)
);

create table public.messages (
  id uuid primary key default gen_random_uuid(),
  team_id uuid not null references public.teams(id) on delete cascade,
  session_id uuid not null references public.sessions(id) on delete cascade,
  sender_actor_id uuid not null references public.actors(id) on delete restrict,
  reply_to_message_id uuid null references public.messages(id) on delete set null,
  kind text not null check (kind in ('text', 'system', 'task_event')),
  content text not null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.agent_runtimes (
  id uuid primary key default gen_random_uuid(),
  team_id uuid not null references public.teams(id) on delete cascade,
  agent_id uuid not null references public.agents(id) on delete cascade,
  session_id uuid not null references public.sessions(id) on delete cascade,
  workspace_id uuid null references public.workspaces(id) on delete set null,
  backend_type text not null check (backend_type in ('claude', 'codex', 'opencode')),
  backend_session_id text null,
  status text not null check (status in ('starting', 'running', 'stopped', 'failed')),
  current_model text null,
  last_seen_at timestamptz null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index idx_actors_team_id on public.actors(team_id);
create index idx_team_members_member_id on public.team_members(member_id);
create index idx_workspaces_team_id on public.workspaces(team_id);
create index idx_tasks_team_id on public.tasks(team_id);
create index idx_tasks_workspace_id on public.tasks(workspace_id);
create index idx_sessions_team_id on public.sessions(team_id);
create index idx_sessions_task_id on public.sessions(task_id);
create index idx_messages_team_id on public.messages(team_id);
create index idx_messages_session_created_at on public.messages(session_id, created_at desc);
create index idx_session_participants_actor_id on public.session_participants(actor_id);
create index idx_agent_runtimes_session_id on public.agent_runtimes(session_id);
create index idx_agent_runtimes_agent_id on public.agent_runtimes(agent_id);

create trigger set_teams_updated_at before update on public.teams
for each row execute function app.bump_updated_at();
create trigger set_actors_updated_at before update on public.actors
for each row execute function app.bump_updated_at();
create trigger set_members_updated_at before update on public.members
for each row execute function app.bump_updated_at();
create trigger set_team_members_updated_at before update on public.team_members
for each row execute function app.bump_updated_at();
create trigger set_workspaces_updated_at before update on public.workspaces
for each row execute function app.bump_updated_at();
create trigger set_agents_updated_at before update on public.agents
for each row execute function app.bump_updated_at();
create trigger set_agent_member_access_updated_at before update on public.agent_member_access
for each row execute function app.bump_updated_at();
create trigger set_tasks_updated_at before update on public.tasks
for each row execute function app.bump_updated_at();
create trigger set_task_external_refs_updated_at before update on public.task_external_refs
for each row execute function app.bump_updated_at();
create trigger set_sessions_updated_at before update on public.sessions
for each row execute function app.bump_updated_at();
create trigger set_session_participants_updated_at before update on public.session_participants
for each row execute function app.bump_updated_at();
create trigger set_messages_updated_at before update on public.messages
for each row execute function app.bump_updated_at();
create trigger set_agent_runtimes_updated_at before update on public.agent_runtimes
for each row execute function app.bump_updated_at();
