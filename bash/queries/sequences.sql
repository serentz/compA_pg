-- Parametres des sequences (la valeur courante n'est pas comparee : elle depend des donnees).
-- Cle : sequence_name.
select schemaname || '.' || sequencename as sequence_name,
       data_type::text as data_type,
       start_value::text as start_value,
       increment_by::text as increment_by,
       min_value::text as min_value,
       max_value::text as max_value,
       cycle::text as cycle,
       cache_size::text as cache_size
  from pg_sequences
 where schemaname not in ('pg_catalog', 'information_schema') and schemaname not like 'pg\_%'
 order by 1
