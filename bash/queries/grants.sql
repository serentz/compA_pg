-- Droits explicites (ACL) sur la base, les schemas, tables/vues/sequences et fonctions.
-- Cle : object_type + object_name + grantee ('PUBLIC' pour tous). privileges : liste triee.
with acls as (
    select 'database' as object_type, datname::text as object_name, datacl as acl
      from pg_database where datname = current_database()
    union all
    select 'schema', nspname, nspacl from pg_namespace
     where nspname not in ('pg_catalog', 'information_schema') and nspname not like 'pg\_%'
    union all
    select case c.relkind when 'S' then 'sequence' else 'table' end, n.nspname || '.' || c.relname, c.relacl
      from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where c.relkind in ('r', 'p', 'v', 'm', 'S')
       and n.nspname not in ('pg_catalog', 'information_schema') and n.nspname not like 'pg\_%'
    union all
    select 'function', n.nspname || '.' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')', p.proacl
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname not in ('pg_catalog', 'information_schema') and n.nspname not like 'pg\_%'
       and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
)
select a.object_type, a.object_name,
       case when x.grantee = 0 then 'PUBLIC' else pg_get_userbyid(x.grantee) end as grantee,
       string_agg(x.privilege_type, ',' order by x.privilege_type) as privileges
  from acls a, aclexplode(a.acl) x
 where a.acl is not null
 group by a.object_type, a.object_name, x.grantee
 order by 1, 2, 3
