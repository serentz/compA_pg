-- Taille de la base et de chaque schema applicatif, en Mo. Cle : item.
select 'database' as item, round(pg_database_size(current_database()) / 1048576.0, 1) as size_mb
union all
select 'schema:' || n.nspname,
       round(coalesce(sum(pg_total_relation_size(c.oid)), 0) / 1048576.0, 1)
  from pg_namespace n
  left join pg_class c on c.relnamespace = n.oid and c.relkind in ('r', 'm', 'p', 't')
 where n.nspname not in ('pg_catalog', 'information_schema') and n.nspname not like 'pg\_%'
 group by n.nspname
 order by 1
