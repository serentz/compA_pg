-- Presence des vues (V), vues materialisees (M), fonctions (F), procedures (P) et triggers (TR).
-- Cle : object_name + object_type. Les fonctions surchargees sont distinguees par leurs arguments.
select n.nspname || '.' || c.relname as object_name,
       case c.relkind when 'v' then 'V' else 'M' end as object_type
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
 where c.relkind in ('v', 'm')
   and n.nspname not in ('pg_catalog', 'information_schema') and n.nspname not like 'pg\_%'
union all
select n.nspname || '.' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')',
       case p.prokind when 'p' then 'P' else 'F' end
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where p.prokind in ('f', 'p')
   and n.nspname not in ('pg_catalog', 'information_schema') and n.nspname not like 'pg\_%'
   and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
union all
select n.nspname || '.' || c.relname || '.' || t.tgname, 'TR'
  from pg_trigger t join pg_class c on c.oid = t.tgrelid join pg_namespace n on n.oid = c.relnamespace
 where not t.tgisinternal
   and n.nspname not in ('pg_catalog', 'information_schema') and n.nspname not like 'pg\_%'
 order by 1, 2
