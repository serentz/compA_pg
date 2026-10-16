-- Options de la base (pg_database) et reglages propres a la base (pg_db_role_setting). Cle : option.
select o.option, o.value
  from pg_database d
  cross join lateral (values
       ('owner', pg_get_userbyid(d.datdba)),
       ('encoding', pg_encoding_to_char(d.encoding)),
       ('collate', d.datcollate),
       ('ctype', d.datctype),
       ('connection_limit', d.datconnlimit::text),
       ('allow_connections', d.datallowconn::text),
       ('is_template', d.datistemplate::text),
       ('tablespace', (select spcname from pg_tablespace where oid = d.dattablespace))
  ) as o(option, value)
 where d.datname = current_database()
union all
select 'setting:' || split_part(s, '=', 1), substr(s, strpos(s, '=') + 1)
  from pg_db_role_setting r, unnest(r.setconfig) as s
 where r.setdatabase = (select oid from pg_database where datname = current_database()) and r.setrole = 0
 order by 1
