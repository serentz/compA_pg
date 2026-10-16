-- Parametres du serveur (pg_settings). Cle : name. Compare : value.
select name, setting as value, coalesce(unit, '') as unit, source
  from pg_settings
 where name not in ('data_directory', 'config_file', 'hba_file', 'ident_file', 'external_pid_file',
                    'unix_socket_directories', 'port', 'cluster_name', 'log_directory',
                    'archive_command', 'application_name', 'search_path')
   and name not like 'lc\_%'
 order by name
