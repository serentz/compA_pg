-- Index. Cle : table_name + index_name. La definition contient colonnes, methode, unicite, predicat.
select n.nspname || '.' || t.relname as table_name,
       i.relname as index_name,
       x.indisunique::text as is_unique,
       x.indisprimary::text as is_primary,
       regexp_replace(pg_get_indexdef(i.oid), '^CREATE (UNIQUE )?INDEX \S+ ON ', '') as definition
  from pg_index x
  join pg_class i on i.oid = x.indexrelid
  join pg_class t on t.oid = x.indrelid
  join pg_namespace n on n.oid = t.relnamespace
 where n.nspname not in ('pg_catalog', 'information_schema') and n.nspname not like 'pg\_%'
 order by 1, 2
