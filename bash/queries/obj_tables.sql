-- Colonnes des tables (y compris partitionnees). Cle : table_name + column_name.
select n.nspname || '.' || c.relname as table_name,
       a.attname as column_name,
       format_type(a.atttypid, a.atttypmod) as type_name,
       a.attnotnull::text as not_null,
       coalesce(pg_get_expr(d.adbin, d.adrelid), '') as default_value,
       case a.attidentity when 'a' then 'ALWAYS' when 'd' then 'BY DEFAULT' else '' end as identity,
       case a.attgenerated when 's' then 'STORED' else '' end as generated
  from pg_attribute a
  join pg_class c on c.oid = a.attrelid and c.relkind in ('r', 'p')
  join pg_namespace n on n.oid = c.relnamespace
  left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
 where a.attnum > 0 and not a.attisdropped
   and n.nspname not in ('pg_catalog', 'information_schema') and n.nspname not like 'pg\_%'
 order by 1, 2
