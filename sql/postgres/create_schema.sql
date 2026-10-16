-- ============================================================================
-- POC comparaison PostgreSQL : schema "compa_pg" (base de resultats)
-- Version du schema : 1.0
--
-- Prerequis : la base PostgreSQL (option -n du script) doit deja exister, ex. :
--     createdb -h <hote> -U <login> compa
-- Execution :
--     psql -h <hote> -U <login> -d compa -f create_schema.sql
--
-- Le script est idempotent : il peut etre rejoue sans effacer les donnees.
-- Aucun mot de passe n'est defini ici (voir la section 7 pour le role Grafana).
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

CREATE SCHEMA IF NOT EXISTS compa_pg;

-- ----------------------------------------------------------------------------
-- 1. Version du schema
--    Le script de comparaison verifie sa presence avant de demarrer :
--    SELECT to_regclass('compa_pg.schema_version') IS NOT NULL;
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS compa_pg.schema_version (
    version     text        PRIMARY KEY,
    applied_at  timestamptz NOT NULL DEFAULT now()
);

INSERT INTO compa_pg.schema_version (version) VALUES ('1.0')
ON CONFLICT (version) DO NOTHING;

-- ----------------------------------------------------------------------------
-- 2. Tables de reference
-- ----------------------------------------------------------------------------

-- Une ligne par couple (instance1/base1, instance2/base2) compare.
CREATE TABLE IF NOT EXISTS compa_pg.ref_execution (
    refid       bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    instance1   text        NOT NULL,
    base1       text        NOT NULL,
    instance2   text        NOT NULL,
    base2       text        NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ux_ref_execution UNIQUE (instance1, base1, instance2, base2)
);
COMMENT ON TABLE compa_pg.ref_execution IS
    'Reference d''execution : un refid par combinaison instance1/base1/instance2/base2 (reutilise si elle existe).';

-- Une ligne par execution du script.
CREATE TABLE IF NOT EXISTS compa_pg.run (
    run_id      bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    refid       bigint      NOT NULL REFERENCES compa_pg.ref_execution (refid),
    ts_exec     timestamptz NOT NULL DEFAULT now(),
    ts_fin      timestamptz,
    statut      text        NOT NULL DEFAULT 'EN_COURS'
                CHECK (statut IN ('EN_COURS', 'TERMINE', 'ERREUR')),
    message     text
);
CREATE INDEX IF NOT EXISTS ix_run_refid_ts ON compa_pg.run (refid, ts_exec DESC);
COMMENT ON TABLE compa_pg.run IS
    'Une ligne par execution (run_id unique) ; les tables diff_* referencent run_id avec suppression en cascade.';

-- Acces aux clusters compares : un login par instance (cluster PostgreSQL).
-- POC : mot de passe stocke en clair (acces limite au role du script).
CREATE TABLE IF NOT EXISTS compa_pg.config_compa_pg (
    instance     text    PRIMARY KEY,
    host         text    NOT NULL,
    port         integer NOT NULL DEFAULT 5432,
    login        text    NOT NULL,
    password     text    NOT NULL,
    actif        boolean NOT NULL DEFAULT true,
    commentaire  text
);
COMMENT ON TABLE compa_pg.config_compa_pg IS
    'Acces aux clusters compares, par instance. Ne jamais versionner de contenu de cette table dans git.';

-- Regles d'exclusion du bruit de comparaison.
--   cle_pattern : motif SQL LIKE applique a la cle de la ligne ('%' = toutes)
--   colonne     : colonne de valeur concernee, '*' = toute la ligne
--   action      : IGNORE (ecart non enregistre) ou ATTENDU (enregistre avec attendu = true)
CREATE TABLE IF NOT EXISTS compa_pg.exclusion_rules (
    rule_id      bigint  GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    module       text    NOT NULL
                 CHECK (module IN ('inst_config', 'db_size', 'db_options', 'obj_tables',
                                   'obj_indexes', 'obj_code', 'obj_source', 'constraints',
                                   'extensions', 'sequences', 'roles', 'grants')),
    cle_pattern  text    NOT NULL DEFAULT '%',
    colonne      text    NOT NULL DEFAULT '*',
    action       text    NOT NULL DEFAULT 'IGNORE' CHECK (action IN ('IGNORE', 'ATTENDU')),
    motif        text,
    actif        boolean NOT NULL DEFAULT true,
    CONSTRAINT ux_exclusion_rules UNIQUE (module, cle_pattern, colonne)
);

-- Regles par defaut : aucune. Exemple pour ignorer un parametre propre a un cluster :
--   INSERT INTO compa_pg.exclusion_rules (module, cle_pattern, colonne, action, motif)
--   VALUES ('inst_config', 'shared_buffers', 'value', 'ATTENDU', 'dimensionne par serveur');

-- ----------------------------------------------------------------------------
-- 3. Tables de differences : une par module
--    Colonnes communes : diff_id, run_id, refid, ts_exec, type_diff, attendu
--    Valeurs du cluster/base 1 prefixees r1_, cluster/base 2 prefixees r2_
--    Une ligne consolidee par difference.
-- ----------------------------------------------------------------------------

-- 3.1 inst_config : cle : name ; r1_/r2_ : valeur, unite, origine du parametre (pg_settings)
CREATE TABLE IF NOT EXISTS compa_pg.diff_inst_config (
    diff_id      bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id       bigint      NOT NULL REFERENCES compa_pg.run (run_id) ON DELETE CASCADE,
    refid        bigint      NOT NULL REFERENCES compa_pg.ref_execution (refid),
    ts_exec      timestamptz NOT NULL,
    type_diff    text        NOT NULL CHECK (type_diff IN ('ONLY_R1', 'ONLY_R2', 'DIFF')),
    attendu      boolean     NOT NULL DEFAULT false,
    name         text        NOT NULL,
    r1_value     text,
    r1_unit      text,
    r1_source    text,
    r2_value     text,
    r2_unit      text,
    r2_source    text,
    CONSTRAINT ux_diff_inst_config UNIQUE (run_id, name)
);

-- 3.2 db_size : cle : item (database ou schema:<nom>), taille en Mo
CREATE TABLE IF NOT EXISTS compa_pg.diff_db_size (
    diff_id      bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id       bigint      NOT NULL REFERENCES compa_pg.run (run_id) ON DELETE CASCADE,
    refid        bigint      NOT NULL REFERENCES compa_pg.ref_execution (refid),
    ts_exec      timestamptz NOT NULL,
    type_diff    text        NOT NULL CHECK (type_diff IN ('ONLY_R1', 'ONLY_R2', 'DIFF')),
    attendu      boolean     NOT NULL DEFAULT false,
    item         text        NOT NULL,
    r1_size_mb   numeric,
    r2_size_mb   numeric,
    CONSTRAINT ux_diff_db_size UNIQUE (run_id, item)
);

-- 3.3 db_options : cle : option (owner, encoding, collate, ctype, setting:<nom>...)
CREATE TABLE IF NOT EXISTS compa_pg.diff_db_options (
    diff_id      bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id       bigint      NOT NULL REFERENCES compa_pg.run (run_id) ON DELETE CASCADE,
    refid        bigint      NOT NULL REFERENCES compa_pg.ref_execution (refid),
    ts_exec      timestamptz NOT NULL,
    type_diff    text        NOT NULL CHECK (type_diff IN ('ONLY_R1', 'ONLY_R2', 'DIFF')),
    attendu      boolean     NOT NULL DEFAULT false,
    option       text        NOT NULL,
    r1_value     text,
    r2_value     text,
    CONSTRAINT ux_diff_db_options UNIQUE (run_id, option)
);

-- 3.4 obj_tables : cle : table_name + column_name
CREATE TABLE IF NOT EXISTS compa_pg.diff_obj_tables (
    diff_id      bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id       bigint      NOT NULL REFERENCES compa_pg.run (run_id) ON DELETE CASCADE,
    refid        bigint      NOT NULL REFERENCES compa_pg.ref_execution (refid),
    ts_exec      timestamptz NOT NULL,
    type_diff    text        NOT NULL CHECK (type_diff IN ('ONLY_R1', 'ONLY_R2', 'DIFF')),
    attendu      boolean     NOT NULL DEFAULT false,
    table_name   text        NOT NULL,
    column_name  text        NOT NULL,
    r1_type_name text,
    r1_not_null  text,
    r1_default_value text,
    r1_identity  text,
    r1_generated text,
    r2_type_name text,
    r2_not_null  text,
    r2_default_value text,
    r2_identity  text,
    r2_generated text,
    CONSTRAINT ux_diff_obj_tables UNIQUE (run_id, table_name, column_name)
);

-- 3.5 obj_indexes : cle : table_name + index_name
CREATE TABLE IF NOT EXISTS compa_pg.diff_obj_indexes (
    diff_id      bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id       bigint      NOT NULL REFERENCES compa_pg.run (run_id) ON DELETE CASCADE,
    refid        bigint      NOT NULL REFERENCES compa_pg.ref_execution (refid),
    ts_exec      timestamptz NOT NULL,
    type_diff    text        NOT NULL CHECK (type_diff IN ('ONLY_R1', 'ONLY_R2', 'DIFF')),
    attendu      boolean     NOT NULL DEFAULT false,
    table_name   text        NOT NULL,
    index_name   text        NOT NULL,
    r1_is_unique text,
    r1_is_primary text,
    r1_definition text,
    r2_is_unique text,
    r2_is_primary text,
    r2_definition text,
    CONSTRAINT ux_diff_obj_indexes UNIQUE (run_id, table_name, index_name)
);

-- 3.6 obj_code : presence des vues (V), vues materialisees (M), fonctions (F),
--     procedures (P) et triggers (TR) ; cle = object_name + object_type
CREATE TABLE IF NOT EXISTS compa_pg.diff_obj_code (
    diff_id      bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id       bigint      NOT NULL REFERENCES compa_pg.run (run_id) ON DELETE CASCADE,
    refid        bigint      NOT NULL REFERENCES compa_pg.ref_execution (refid),
    ts_exec      timestamptz NOT NULL,
    type_diff    text        NOT NULL CHECK (type_diff IN ('ONLY_R1', 'ONLY_R2', 'DIFF')),
    attendu      boolean     NOT NULL DEFAULT false,
    object_name  text        NOT NULL,
    object_type  text        NOT NULL,
    r1_present   boolean     NOT NULL DEFAULT false,
    r2_present   boolean     NOT NULL DEFAULT false,
    CONSTRAINT ux_diff_obj_code UNIQUE (run_id, object_name, object_type)
);

-- 3.7 obj_source : contenu du code ; cle = object_name + object_type
--     Le hash MD5 sert a la comparaison ; les textes (pg_get_viewdef, pg_get_functiondef,
--     pg_get_triggerdef) ne sont stockes que pour les objets en ecart.
CREATE TABLE IF NOT EXISTS compa_pg.diff_obj_source (
    diff_id      bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id       bigint      NOT NULL REFERENCES compa_pg.run (run_id) ON DELETE CASCADE,
    refid        bigint      NOT NULL REFERENCES compa_pg.ref_execution (refid),
    ts_exec      timestamptz NOT NULL,
    type_diff    text        NOT NULL CHECK (type_diff IN ('ONLY_R1', 'ONLY_R2', 'DIFF')),
    attendu      boolean     NOT NULL DEFAULT false,
    object_name    text        NOT NULL,
    object_type    text        NOT NULL,
    r1_hash        text,
    r1_nb_lignes   integer,
    r1_source      text,
    r2_hash        text,
    r2_nb_lignes   integer,
    r2_source      text,
    CONSTRAINT ux_diff_obj_source UNIQUE (run_id, object_name, object_type)
);

-- 3.8 constraints : cle : table_name + constraint_name (p, f, u, c, x ; la definition inclut les actions des cles etrangeres)
CREATE TABLE IF NOT EXISTS compa_pg.diff_constraints (
    diff_id      bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id       bigint      NOT NULL REFERENCES compa_pg.run (run_id) ON DELETE CASCADE,
    refid        bigint      NOT NULL REFERENCES compa_pg.ref_execution (refid),
    ts_exec      timestamptz NOT NULL,
    type_diff    text        NOT NULL CHECK (type_diff IN ('ONLY_R1', 'ONLY_R2', 'DIFF')),
    attendu      boolean     NOT NULL DEFAULT false,
    table_name   text        NOT NULL,
    constraint_name text        NOT NULL,
    r1_constraint_type text,
    r1_definition text,
    r2_constraint_type text,
    r2_definition text,
    CONSTRAINT ux_diff_constraints UNIQUE (run_id, table_name, constraint_name)
);

-- 3.9 extensions : cle : extension
CREATE TABLE IF NOT EXISTS compa_pg.diff_extensions (
    diff_id      bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id       bigint      NOT NULL REFERENCES compa_pg.run (run_id) ON DELETE CASCADE,
    refid        bigint      NOT NULL REFERENCES compa_pg.ref_execution (refid),
    ts_exec      timestamptz NOT NULL,
    type_diff    text        NOT NULL CHECK (type_diff IN ('ONLY_R1', 'ONLY_R2', 'DIFF')),
    attendu      boolean     NOT NULL DEFAULT false,
    extension    text        NOT NULL,
    r1_version   text,
    r1_schema    text,
    r2_version   text,
    r2_schema    text,
    CONSTRAINT ux_diff_extensions UNIQUE (run_id, extension)
);

-- 3.10 sequences : cle : sequence_name
CREATE TABLE IF NOT EXISTS compa_pg.diff_sequences (
    diff_id      bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id       bigint      NOT NULL REFERENCES compa_pg.run (run_id) ON DELETE CASCADE,
    refid        bigint      NOT NULL REFERENCES compa_pg.ref_execution (refid),
    ts_exec      timestamptz NOT NULL,
    type_diff    text        NOT NULL CHECK (type_diff IN ('ONLY_R1', 'ONLY_R2', 'DIFF')),
    attendu      boolean     NOT NULL DEFAULT false,
    sequence_name text        NOT NULL,
    r1_data_type text,
    r1_start_value text,
    r1_increment_by text,
    r1_min_value text,
    r1_max_value text,
    r1_cycle     text,
    r1_cache_size text,
    r2_data_type text,
    r2_start_value text,
    r2_increment_by text,
    r2_min_value text,
    r2_max_value text,
    r2_cycle     text,
    r2_cache_size text,
    CONSTRAINT ux_diff_sequences UNIQUE (run_id, sequence_name)
);

-- 3.11 roles : cle : role_name (roles du cluster hors pg_*)
CREATE TABLE IF NOT EXISTS compa_pg.diff_roles (
    diff_id      bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id       bigint      NOT NULL REFERENCES compa_pg.run (run_id) ON DELETE CASCADE,
    refid        bigint      NOT NULL REFERENCES compa_pg.ref_execution (refid),
    ts_exec      timestamptz NOT NULL,
    type_diff    text        NOT NULL CHECK (type_diff IN ('ONLY_R1', 'ONLY_R2', 'DIFF')),
    attendu      boolean     NOT NULL DEFAULT false,
    role_name    text        NOT NULL,
    r1_can_login text,
    r1_superuser text,
    r1_create_db text,
    r1_create_role text,
    r1_inherit   text,
    r1_replication text,
    r1_bypass_rls text,
    r1_conn_limit text,
    r1_member_of text,
    r2_can_login text,
    r2_superuser text,
    r2_create_db text,
    r2_create_role text,
    r2_inherit   text,
    r2_replication text,
    r2_bypass_rls text,
    r2_conn_limit text,
    r2_member_of text,
    CONSTRAINT ux_diff_roles UNIQUE (run_id, role_name)
);

-- 3.12 grants : cle : object_type + object_name + grantee ; privileges = liste triee
CREATE TABLE IF NOT EXISTS compa_pg.diff_grants (
    diff_id      bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id       bigint      NOT NULL REFERENCES compa_pg.run (run_id) ON DELETE CASCADE,
    refid        bigint      NOT NULL REFERENCES compa_pg.ref_execution (refid),
    ts_exec      timestamptz NOT NULL,
    type_diff    text        NOT NULL CHECK (type_diff IN ('ONLY_R1', 'ONLY_R2', 'DIFF')),
    attendu      boolean     NOT NULL DEFAULT false,
    object_type  text        NOT NULL,
    object_name  text        NOT NULL,
    grantee      text        NOT NULL,
    r1_privileges text,
    r2_privileges text,
    CONSTRAINT ux_diff_grants UNIQUE (run_id, object_type, object_name, grantee)
);

-- Index de consultation (selecteur de run Grafana, filtres par type d'ecart)
DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['diff_inst_config',
                             'diff_db_size',
                             'diff_db_options',
                             'diff_obj_tables',
                             'diff_obj_indexes',
                             'diff_obj_code',
                             'diff_obj_source',
                             'diff_constraints',
                             'diff_extensions',
                             'diff_sequences',
                             'diff_roles',
                             'diff_grants']
    LOOP
        EXECUTE format('CREATE INDEX IF NOT EXISTS ix_%s_run ON compa_pg.%I (run_id, type_diff)', t, t);
        EXECUTE format('CREATE INDEX IF NOT EXISTS ix_%s_refid_ts ON compa_pg.%I (refid, ts_exec DESC)', t, t);
    END LOOP;
END
$$;

-- ----------------------------------------------------------------------------
-- 4. Fonctions utilitaires pour le script de comparaison
-- ----------------------------------------------------------------------------

-- Retourne le refid de la combinaison, en le creant s'il n'existe pas.
CREATE OR REPLACE FUNCTION compa_pg.get_or_create_refid(
    p_instance1 text, p_base1 text, p_instance2 text, p_base2 text
) RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
    v_refid bigint;
BEGIN
    SELECT refid INTO v_refid
      FROM compa_pg.ref_execution
     WHERE instance1 = p_instance1 AND base1 = p_base1
       AND instance2 = p_instance2 AND base2 = p_base2;

    IF v_refid IS NULL THEN
        INSERT INTO compa_pg.ref_execution (instance1, base1, instance2, base2)
        VALUES (p_instance1, p_base1, p_instance2, p_base2)
        ON CONFLICT (instance1, base1, instance2, base2) DO NOTHING
        RETURNING refid INTO v_refid;

        -- cas de concurrence : un autre processus vient de la creer
        IF v_refid IS NULL THEN
            SELECT refid INTO v_refid
              FROM compa_pg.ref_execution
             WHERE instance1 = p_instance1 AND base1 = p_base1
               AND instance2 = p_instance2 AND base2 = p_base2;
        END IF;
    END IF;

    RETURN v_refid;
END
$$;

-- Ouvre une execution et retourne son run_id.
CREATE OR REPLACE FUNCTION compa_pg.start_run(p_refid bigint)
RETURNS bigint
LANGUAGE sql
AS $$
    INSERT INTO compa_pg.run (refid) VALUES (p_refid) RETURNING run_id;
$$;

-- Cloture une execution.
CREATE OR REPLACE FUNCTION compa_pg.end_run(p_run_id bigint, p_statut text, p_message text DEFAULT NULL)
RETURNS void
LANGUAGE sql
AS $$
    UPDATE compa_pg.run
       SET ts_fin = now(), statut = p_statut, message = p_message
     WHERE run_id = p_run_id;
$$;

-- ----------------------------------------------------------------------------
-- 5. Vues pour Grafana
-- ----------------------------------------------------------------------------

-- Selecteur de run : timestamp + instance1/base1 + instance2/base2
CREATE OR REPLACE VIEW compa_pg.v_run_selector AS
SELECT r.run_id,
       r.ts_exec,
       r.statut,
       e.refid,
       e.instance1, e.base1, e.instance2, e.base2,
       to_char(r.ts_exec AT TIME ZONE 'Europe/Paris', 'YYYY-MM-DD HH24:MI:SS')
           || ' | ' || e.instance1 || '.' || e.base1
           || ' vs ' || e.instance2 || '.' || e.base2 AS libelle
  FROM compa_pg.run r
  JOIN compa_pg.ref_execution e USING (refid);

-- Synthese des ecarts par run, module et type (page d'accueil Grafana)
CREATE OR REPLACE VIEW compa_pg.v_synthese_run AS
          SELECT run_id, 'inst_config'::text AS module, type_diff, attendu, count(*) AS nb FROM compa_pg.diff_inst_config GROUP BY run_id, type_diff, attendu
UNION ALL SELECT run_id, 'db_size', type_diff, attendu, count(*) FROM compa_pg.diff_db_size GROUP BY run_id, type_diff, attendu
UNION ALL SELECT run_id, 'db_options', type_diff, attendu, count(*) FROM compa_pg.diff_db_options GROUP BY run_id, type_diff, attendu
UNION ALL SELECT run_id, 'obj_tables', type_diff, attendu, count(*) FROM compa_pg.diff_obj_tables GROUP BY run_id, type_diff, attendu
UNION ALL SELECT run_id, 'obj_indexes', type_diff, attendu, count(*) FROM compa_pg.diff_obj_indexes GROUP BY run_id, type_diff, attendu
UNION ALL SELECT run_id, 'obj_code', type_diff, attendu, count(*) FROM compa_pg.diff_obj_code GROUP BY run_id, type_diff, attendu
UNION ALL SELECT run_id, 'obj_source', type_diff, attendu, count(*) FROM compa_pg.diff_obj_source GROUP BY run_id, type_diff, attendu
UNION ALL SELECT run_id, 'constraints', type_diff, attendu, count(*) FROM compa_pg.diff_constraints GROUP BY run_id, type_diff, attendu
UNION ALL SELECT run_id, 'extensions', type_diff, attendu, count(*) FROM compa_pg.diff_extensions GROUP BY run_id, type_diff, attendu
UNION ALL SELECT run_id, 'sequences', type_diff, attendu, count(*) FROM compa_pg.diff_sequences GROUP BY run_id, type_diff, attendu
UNION ALL SELECT run_id, 'roles', type_diff, attendu, count(*) FROM compa_pg.diff_roles GROUP BY run_id, type_diff, attendu
UNION ALL SELECT run_id, 'grants', type_diff, attendu, count(*) FROM compa_pg.diff_grants GROUP BY run_id, type_diff, attendu;

-- ----------------------------------------------------------------------------
-- 6. Documentation des colonnes cles
-- ----------------------------------------------------------------------------
COMMENT ON COLUMN compa_pg.diff_inst_config.type_diff IS 'ONLY_R1 : present seulement cote 1 ; ONLY_R2 : seulement cote 2 ; DIFF : valeurs differentes';
COMMENT ON COLUMN compa_pg.diff_inst_config.attendu   IS 'true si l''ecart correspond a une regle d''exclusion de type ATTENDU';

-- ----------------------------------------------------------------------------
-- 7. Role Grafana en lecture seule
--    Le role est cree SANS mot de passe (aucun secret dans git).
--    Apres execution, definir le mot de passe manuellement :
--        ALTER ROLE grafana_ro LOGIN PASSWORD '<a_definir>';
-- ----------------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'grafana_ro') THEN
        CREATE ROLE grafana_ro NOLOGIN;
    END IF;
END
$$;

GRANT USAGE ON SCHEMA compa_pg TO grafana_ro;
GRANT SELECT ON ALL TABLES IN SCHEMA compa_pg TO grafana_ro;
-- config_compa_pg contient des mots de passe : jamais lisible par Grafana
REVOKE ALL ON compa_pg.config_compa_pg FROM grafana_ro;
ALTER DEFAULT PRIVILEGES IN SCHEMA compa_pg GRANT SELECT ON TABLES TO grafana_ro;

COMMIT;
