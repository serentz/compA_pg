-- Roles du cluster (hors roles systeme pg_*) et appartenances. Cle : role_name.
select r.rolname as role_name,
       r.rolcanlogin::text as can_login,
       r.rolsuper::text as superuser,
       r.rolcreatedb::text as create_db,
       r.rolcreaterole::text as create_role,
       r.rolinherit::text as inherit,
       r.rolreplication::text as replication,
       r.rolbypassrls::text as bypass_rls,
       r.rolconnlimit::text as conn_limit,
       coalesce((select string_agg(g.rolname, ',' order by g.rolname)
                   from pg_auth_members m join pg_roles g on g.oid = m.roleid
                  where m.member = r.oid), '') as member_of
  from pg_roles r
 where r.rolname not like 'pg\_%'
 order by 1
