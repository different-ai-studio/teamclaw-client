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
