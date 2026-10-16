-- Extensions installees. Cle : extension.
select e.extname as extension, e.extversion as version, n.nspname as schema
  from pg_extension e join pg_namespace n on n.oid = e.extnamespace
 order by 1
