-- rls_cross_tenant.sql
--
-- Safety net for the multi-tenant promise: on a shared instance (the future
-- cloud, but also any self-host with several families) one family must never
-- see or touch another's rows. RLS scopes everything by family_id; this test
-- proves it, end to end, the way a real client hits the DB:
--
--   set role authenticated  +  request.jwt.claims = {"sub": <user uuid>}
--   → auth.uid() resolves → familyfocal.auth_family_id() scopes every query.
--
-- It builds two throwaway families (A, B), then asserts isolation for a
-- parent, a child, and the other family's parent. SELECT, INSERT and UPDATE
-- are all checked. Any leak RAISEs and fails the run.
--
-- 100% side-effect free: everything runs inside one transaction that ROLLs
-- BACK. Nothing is ever committed, so it is safe to run against a live DB.
-- Run via scripts/run_rls_tests.sh (docker exec psql).

\set ON_ERROR_STOP on

begin;

do $$
declare
  ua uuid := gen_random_uuid();   -- auth user: parent A
  ub uuid := gen_random_uuid();   -- auth user: parent B
  uc uuid := gen_random_uuid();   -- auth user: child  A
  fa uuid;  fb uuid;              -- families
  pa uuid;  ca uuid;  pb uuid;    -- profiles
  n  int;
begin
  ---------------------------------------------------------------------------
  -- Setup. Runs as the invoking superuser, so RLS is bypassed here on purpose.
  ---------------------------------------------------------------------------
  insert into auth.users(id) values (ua), (ub), (uc);

  insert into familyfocal.families(name, created_by) values ('Test Fam A', ua) returning id into fa;
  insert into familyfocal.families(name, created_by) values ('Test Fam B', ub) returning id into fb;

  insert into familyfocal.profiles(family_id, user_id, role, name)
    values (fa, ua, 'parent', 'Parent A') returning id into pa;
  insert into familyfocal.profiles(family_id, user_id, role, name)
    values (fa, uc, 'child',  'Child A')  returning id into ca;
  insert into familyfocal.profiles(family_id, user_id, role, name)
    values (fb, ub, 'parent', 'Parent B') returning id into pb;

  insert into familyfocal.tasks(id, family_id, assignee_profile_id, title)
    values (gen_random_uuid(), fa, ca, 'Task A');
  insert into familyfocal.tasks(id, family_id, title)
    values (gen_random_uuid(), fb, 'Task B');

  ---------------------------------------------------------------------------
  -- From here on, act as an ordinary signed-in client.
  ---------------------------------------------------------------------------
  execute 'set local role authenticated';

  -- ===== Parent A =====================================================
  perform set_config('request.jwt.claims', json_build_object('sub', ua)::text, true);

  if familyfocal.auth_family_id() <> fa then
    raise exception 'parent A: auth_family_id() did not resolve to own family';
  end if;
  if not familyfocal.auth_is_parent() then
    raise exception 'parent A: auth_is_parent() returned false';
  end if;

  select count(*) into n from familyfocal.profiles;
  if n <> 2 then
    raise exception 'LEAK: parent A sees % profiles, expected 2 (own family only)', n;
  end if;

  select count(*) into n from familyfocal.tasks;
  if n <> 1 then
    raise exception 'LEAK: parent A sees % tasks, expected 1 (own family only)', n;
  end if;

  -- Writing into another family must be denied by the WITH CHECK clause.
  begin
    insert into familyfocal.profiles(family_id, role, name) values (fb, 'child', 'Sneak');
    raise exception 'SECURITY: parent A was allowed to INSERT a profile into family B';
  exception
    when insufficient_privilege then null;  -- expected: RLS rejected it
  end;

  -- Updating another family's rows must affect zero rows (they are invisible).
  update familyfocal.profiles set name = 'hacked' where name = 'Parent B';
  get diagnostics n = row_count;
  if n <> 0 then
    raise exception 'SECURITY: parent A UPDATEd % rows belonging to family B', n;
  end if;

  -- Positive control: a parent must be able to write within their own family.
  begin
    insert into familyfocal.profiles(family_id, role, name) values (fa, 'child', 'Legit A');
  exception
    when others then
      raise exception 'parent A was wrongly DENIED an insert into own family: %', sqlerrm;
  end;

  -- ===== Child A ======================================================
  perform set_config('request.jwt.claims', json_build_object('sub', uc)::text, true);

  -- profiles policy: a child sees only their own profile.
  select count(*) into n from familyfocal.profiles;
  if n <> 1 then
    raise exception 'child A sees % profiles, expected 1 (self only)', n;
  end if;

  -- tasks policy: a child sees tasks assigned to them — and nothing from family B.
  select count(*) into n from familyfocal.tasks;
  if n <> 1 then
    raise exception 'child A sees % tasks, expected 1 (own assignment only)', n;
  end if;

  -- ===== Parent B (isolation is symmetric) ============================
  perform set_config('request.jwt.claims', json_build_object('sub', ub)::text, true);

  if familyfocal.auth_family_id() <> fb then
    raise exception 'parent B: auth_family_id() did not resolve to own family';
  end if;

  select count(*) into n from familyfocal.profiles;
  if n <> 1 then
    raise exception 'LEAK: parent B sees % profiles, expected 1 (own family only)', n;
  end if;

  select count(*) into n from familyfocal.tasks;
  if n <> 1 then
    raise exception 'LEAK: parent B sees % tasks, expected 1 (own family only)', n;
  end if;

  raise notice '✓ cross-tenant RLS isolation holds — profiles + tasks, A<->B, parent & child';
end $$;

rollback;
