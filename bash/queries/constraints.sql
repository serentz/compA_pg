-- Contraintes : cle primaire (p), etrangere (f), unique (u), controle (c), exclusion (x).
-- Cle : table_name + constraint_name. La definition inclut les cibles et actions des cles etrangeres.
select n.nspname || '.' || c.relname as table_name,
       k.conname as constraint_name,
       k.contype::text as constraint_type,
       pg_get_constraintdef(k.oid) as definition
  from pg_constraint k
  join pg_class c on c.oid = k.conrelid
  join pg_namespace n on n.oid = c.relnamespace
 where k.contype in ('p', 'f', 'u', 'c', 'x')
   and n.nspname not in ('pg_catalog', 'information_schema') and n.nspname not like 'pg\_%'
 order by 1, 2
