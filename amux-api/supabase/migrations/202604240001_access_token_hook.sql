-- Supabase Custom Access Token Hook: injects MQTT-ready claims into every JWT.
-- See docs/specs/2026-04-24-supabase-access-token-hook.md for the design.

-- --------------------------------------------------------------------------
-- Index: hook queries actors by user_id on every token issuance.
-- The existing actors_team_user_idx is composite (team_id, user_id) and
-- cannot efficiently serve user_id-only lookups.
-- --------------------------------------------------------------------------
create index if not exists idx_actors_user_id
  on public.actors (user_id)
  where user_id is not null;

-- --------------------------------------------------------------------------
-- Rule catalog. Pure function; edit this (in a new migration) to change the
-- ACL shape. Unknown actor_type returns zero rows.
-- --------------------------------------------------------------------------
create or replace function public.amux_acl_rules_for(
  p_team  uuid,
  p_actor uuid,
  p_type  text
) returns table (action text, topic text)
language sql
immutable
set search_path = public
as $$
  -- Member (iOS human): team-wide read, team-wide command/RPC publish.
  select action, topic
    from (values
      ('sub', format('amux/%s/user/%s/notify',              p_team, p_actor)),
      ('sub', format('amux/%s/session/+/live',              p_team)),
      ('sub', format('amux/%s/device/+/state',              p_team)),
      ('sub', format('amux/%s/device/+/runtime/+/state',    p_team)),
      ('sub', format('amux/%s/device/+/runtime/+/events',   p_team)),
      ('sub', format('amux/%s/device/+/rpc/res',            p_team)),
      ('pub', format('amux/%s/device/+/rpc/req',            p_team)),
      ('pub', format('amux/%s/device/+/runtime/+/commands', p_team))
    ) as r(action, topic)
   where p_type = 'member';
$$;
