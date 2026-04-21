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

rollback;
