begin;

-- Table exists with the expected columns.
do $$
begin
  if not exists (select 1 from information_schema.tables
                 where table_schema='public' and table_name='daemon_invites') then
    raise exception 'daemon_invites table not created';
  end if;

  if not exists (select 1 from information_schema.columns
                 where table_schema='public' and table_name='daemon_invites'
                   and column_name='invite_token') then
    raise exception 'daemon_invites.invite_token missing';
  end if;
end;
$$;

-- RLS: daemon_invites is read-restricted; anon cannot read by default.
do $$
declare
  v_enabled boolean;
begin
  select c.relrowsecurity into v_enabled
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname='public' and c.relname='daemon_invites';

  if not v_enabled then
    raise exception 'RLS not enabled on daemon_invites';
  end if;
end;
$$;

-- create_daemon_invite: happy path creates agent, actor, invite.
do $$
declare
  v_team uuid := gen_random_uuid();
  v_actor_member uuid := gen_random_uuid();
  v_result record;
begin
  -- auth.users satisfies the members.user_id FK; id is the only required field.
  insert into auth.users (id) values (v_actor_member);
  insert into public.teams (id, slug, name) values (v_team, 'inv-test', 'Invite Test');
  insert into public.actors (id, team_id, actor_type, display_name)
    values (v_actor_member, v_team, 'member', 'owner');
  -- members.user_id drives app.current_member_id() (auth.uid() = user_id),
  -- so we set it to the same uuid the JWT 'sub' claim will carry below.
  insert into public.members (id, user_id, status)
    values (v_actor_member, v_actor_member, 'active');
  insert into public.team_members (team_id, member_id, role)
    values (v_team, v_actor_member, 'owner');

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_actor_member::text,
                      'role', 'authenticated')::text, true);

  select *
    into v_result
    from public.create_daemon_invite(v_team, 'My MacBook');

  if v_result.invite_token is null then
    raise exception 'create_daemon_invite did not return invite_token';
  end if;

  if not exists (
    select 1 from public.agents
    where id = v_result.agent_id and status = 'invited'
  ) then
    raise exception 'agent row not inserted as invited';
  end if;
end;
$$;

rollback;
