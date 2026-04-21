# amux-api

Schema-first Supabase workspace for AMUX collaboration data.

## Scope

Phase 1 includes:

- team tenancy
- actors, members, and agents
- team membership
- workspaces
- tasks
- task external refs
- sessions
- session participants
- messages
- agent member access
- light agent runtime state
- RLS policies

Phase 1 excludes:

- HTTP API handlers
- full runtime event persistence
- actor presence tables
- external issue sync

## Local workflow

From `amux-api/`:

```bash
supabase start
supabase db reset
supabase test db
```

## Implemented in phase 1

- team tenancy and membership
- shared-key actors with member/agent subtypes
- team-scoped workspaces
- tasks and external issue links
- task-owned sessions
- session participants
- durable collaboration messages
- agent member permissions (`view`, `prompt`, `admin`)
- light agent runtime state

## Deferred

- actor online presence table
- full runtime event persistence
- external issue sync
- HTTP handlers beyond the database boundary
