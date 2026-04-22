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

-- (blocks added by subsequent tasks)

commit;
