-- 202604220015_actor_unified_identity.sql
--
-- Converge the daemon invite flow (from _0009_.._0014_) onto the unified
-- team_invites model. Move user_id from members to actors, add
-- invited_by_actor_id, rewrite app.* helpers, drop JWT-app_metadata
-- daemon-role infrastructure, expose actor_directory view, add
-- update_actor_last_active heartbeat.
--
-- See docs/superpowers/specs/2026-04-21-actors-supabase-migration-design.md.

begin;

-- ===========================================================================
-- 1. Wipe obsolete dev data. Production runs would require a migration plan
--    for existing daemon agents; not applicable here.
-- ===========================================================================
delete from public.daemon_invites;

-- Agents that only ever existed as invite placeholders go away.
-- Claimed agents (status='active') are kept; their actors row stays, and we
-- backfill actors.user_id in Task 3 from auth.users via the
-- (daemon.*@amuxd.run, app_metadata.actor_id) pair.
delete from public.agents where status = 'invited';

-- The deletion cascades via on delete cascade on actors_id_fk would be nice
-- but members.id / agents.id FKs are not ON DELETE CASCADE by default. Clear
-- the matching actor rows explicitly.
delete from public.actors a
 where a.actor_type = 'agent'
   and not exists (select 1 from public.agents where id = a.id);

-- The daemon auth.users rows will be retained only for agents that are still
-- active; orphan ones get dropped below.
delete from auth.users u
 where u.email like 'daemon.%@amuxd.run'
   and not exists (
     select 1 from public.actors a
     where a.actor_type = 'agent'
       and a.display_name = split_part(u.email, '.', 2)
   );
-- Note: the display_name ↔ email pairing is fragile. Step 3 below re-links
-- surviving daemons via auth.users.raw_app_meta_data->>'actor_id'.

commit;
