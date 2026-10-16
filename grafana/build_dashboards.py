#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Genere les dashboards Grafana du projet (grafana/dashboards/*.json).

    python3 grafana/build_dashboards.py            # ecrit les JSON dans grafana/dashboards/

13 dashboards : une synthese + un par module de comparaison. Chacun porte :
  - la variable `run` (selecteur : date | instance1.base1 vs instance2.base2), identique partout ;
  - une barre de liens vers tous les dashboards du projet (tag `compa_pg`), avec
    includeVars=true : le run choisi est conserve quand on passe d'un module a l'autre.

Les requetes lisent les tables et vues du schema PostgreSQL `compa_pg`
(sql/postgres/create_schema.sql). Les JSON sont versionnes ; modifier ce generateur puis le relancer
plutot que d'editer les JSON a la main (le test grafana/tests/test_dashboards.py verifie la coherence).
"""
import json
import os
import sys

OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "dashboards")

DS = {"type": "grafana-postgresql-datasource", "uid": "compa_pg_ds"}
TAG = "compa_pg"

# `${run:sqlstring}` donne '12' (ou '' si aucun run) ; nullif evite l'erreur de conversion sur ''
RUN_ID = "nullif(${run:sqlstring}, '')::bigint"
RUN_QUERY = ("select run_id::text as __value, libelle as __text from compa_pg.v_run_selector "
             "where statut = 'TERMINE' order by ts_exec desc, run_id desc")

# (cle, uid, titre, table de differences) : le prefixe numerique du titre fixe l'ordre de la barre de liens
HOME = ("home", "compapg-home", "00 - Synthèse")
MODULES = [
    ("inst_config", "compapg-inst_config", "01 - Configuration du cluster", "diff_inst_config"),
    ("db_size", "compapg-db_size", "02 - Taille de la base", "diff_db_size"),
    ("db_options", "compapg-db_options", "03 - Options de la base", "diff_db_options"),
    ("obj_tables", "compapg-obj_tables", "04 - Structure des tables", "diff_obj_tables"),
    ("obj_indexes", "compapg-obj_indexes", "05 - Index", "diff_obj_indexes"),
    ("obj_code", "compapg-obj_code", "06 - Vues, fonctions, triggers", "diff_obj_code"),
    ("obj_source", "compapg-obj_source", "07 - Code source", "diff_obj_source"),
    ("constraints", "compapg-constraints", "08 - Contraintes et clés étrangères", "diff_constraints"),
    ("extensions", "compapg-extensions", "09 - Extensions", "diff_extensions"),
    ("sequences", "compapg-sequences", "10 - Séquences", "diff_sequences"),
    ("roles", "compapg-roles", "11 - Rôles", "diff_roles"),
    ("grants", "compapg-grants", "12 - Droits", "diff_grants"),
]

TYPE_SQL = ("case type_diff when 'ONLY_R1' then 'Seulement R1' when 'ONLY_R2' then 'Seulement R2' "
            "else 'Différent' end as \"Type\"")
ATTENDU_SQL = "case when attendu then 'Oui' else '' end as \"Attendu\""
WHERE_RUN = f"run_id = {RUN_ID}"


def champs(fields):
    """Colonne 'Champs en ecart' : liste des champs qui different (lignes DIFF uniquement)."""
    parts = ", ".join(f"case when r1_{f} is distinct from r2_{f} then '{f}' end" for f in fields)
    return f"case when type_diff = 'DIFF' then nullif(concat_ws(', ', {parts}), '') end as \"Champs en écart\""


# --- Requetes de la table principale de chaque module ---------------------------------------
OBJ_LABEL_SQL = ("case object_type when 'P' then 'Procédure' when 'F' then 'Fonction' when 'V' then 'Vue' "
                 "when 'M' then 'Vue matérialisée' when 'TR' then 'Trigger' else object_type end as \"Objet\"")

# Modules a colonnes textuelles : (colonnes cle -> libelle, champs de valeur -> libelle, champs comparés)
GENERIC = {
    "inst_config": ([("name", "Paramètre")], [("value", "valeur"), ("unit", "unité"), ("source", "origine")], ["value"]),
    "db_options": ([("option", "Option")], [("value", "valeur")], ["value"]),
    "obj_tables": ([("table_name", "Table"), ("column_name", "Colonne")],
                   [("type_name", "type"), ("not_null", "not null"), ("default_value", "défaut"),
                    ("identity", "identity"), ("generated", "générée")],
                   ["type_name", "not_null", "default_value", "identity", "generated"]),
    "obj_indexes": ([("table_name", "Table"), ("index_name", "Index")],
                    [("is_unique", "unique"), ("is_primary", "primaire"), ("definition", "définition")],
                    ["is_unique", "is_primary", "definition"]),
    "constraints": ([("table_name", "Table"), ("constraint_name", "Contrainte")],
                    [("constraint_type", "type"), ("definition", "définition")], ["constraint_type", "definition"]),
    "extensions": ([("extension", "Extension")], [("version", "version"), ("schema", "schéma")], ["version", "schema"]),
    "sequences": ([("sequence_name", "Séquence")],
                  [("data_type", "type"), ("start_value", "début"), ("increment_by", "pas"), ("min_value", "min"),
                   ("max_value", "max"), ("cycle", "cycle"), ("cache_size", "cache")],
                  ["data_type", "start_value", "increment_by", "min_value", "max_value", "cycle", "cache_size"]),
    "roles": ([("role_name", "Rôle")],
              [("can_login", "login"), ("superuser", "superuser"), ("create_db", "createdb"), ("create_role", "createrole"),
               ("inherit", "inherit"), ("replication", "replication"), ("bypass_rls", "bypassrls"),
               ("conn_limit", "limite conn."), ("member_of", "membre de")],
              ["can_login", "superuser", "create_db", "create_role", "inherit", "replication", "bypass_rls",
               "conn_limit", "member_of"]),
    "grants": ([("object_type", "Type d'objet"), ("object_name", "Objet"), ("grantee", "Bénéficiaire")],
               [("privileges", "droits")], ["privileges"]),
}


def main_table_sql(key):
    t = f"compa_pg.diff_{key}"
    if key in GENERIC:
        keys, values, compared = GENERIC[key]
        cols = [f"{k} as \"{lbl}\"" for k, lbl in keys]
        for side in ("r1", "r2"):
            cols += [f"{side}_{f} as \"{side.upper()} {lbl}\"" for f, lbl in values]
        order = ", ".join(k for k, _ in keys)
        return (f"select {TYPE_SQL}, {', '.join(cols)}, {champs(compared)}, {ATTENDU_SQL} "
                f"from {t} where {WHERE_RUN} order by type_diff, {order}")
    if key == "db_size":
        return (f"select {TYPE_SQL}, item as \"Élément\", r1_size_mb as \"R1 taille (Mo)\", "
                f"r2_size_mb as \"R2 taille (Mo)\", (r2_size_mb - r1_size_mb) as \"Écart R2-R1 (Mo)\", "
                f"{champs(['size_mb'])}, {ATTENDU_SQL} "
                f"from {t} where {WHERE_RUN} order by type_diff, item")
    if key == "obj_code":
        return (f"select {TYPE_SQL}, object_name as \"Nom\", {OBJ_LABEL_SQL}, "
                f"case when r1_present then '✓' else '✗' end as \"Présent R1\", "
                f"case when r2_present then '✓' else '✗' end as \"Présent R2\", {ATTENDU_SQL} "
                f"from {t} where {WHERE_RUN} order by type_diff, object_type, object_name")
    if key == "obj_source":
        return (f"select {TYPE_SQL}, object_name as \"Nom\", {OBJ_LABEL_SQL}, "
                f"r1_nb_lignes as \"R1 lignes\", r2_nb_lignes as \"R2 lignes\", "
                f"left(r1_hash, 10) as \"R1 hash\", left(r2_hash, 10) as \"R2 hash\", {ATTENDU_SQL} "
                f"from {t} where {WHERE_RUN} order by type_diff, object_type, object_name")
    raise KeyError(key)


# Comparaison ligne a ligne du code source de l'objet choisi (variables `objet` et `filtre`).
# Comparaison par position : une insertion decale les lignes suivantes (limite du POC).
SOURCE_LINES_SQL = (
    "with src as (select r1_source, r2_source from compa_pg.diff_obj_source "
    f"where {WHERE_RUN} "
    "and object_name = split_part(${objet:sqlstring}, '|', 1) "
    "and object_type = split_part(${objet:sqlstring}, '|', 2)), "
    "a as (select t.n, t.l from src, regexp_split_to_table(coalesce(r1_source, ''), E'\\n') with ordinality as t(l, n)), "
    "b as (select t.n, t.l from src, regexp_split_to_table(coalesce(r2_source, ''), E'\\n') with ordinality as t(l, n)) "
    "select coalesce(a.n, b.n) as \"Ligne\", a.l as \"R1\", b.l as \"R2\", "
    "case when a.l is distinct from b.l then '≠' else '' end as \"Écart\" "
    "from a full join b on a.n = b.n "
    "where ${filtre:sqlstring} = 'toutes' or a.l is distinct from b.l "
    "order by 1"
)
OBJET_QUERY = ("select object_name || ' (' || object_type || ')' as __text, "
               "object_name || '|' || object_type as __value from compa_pg.diff_obj_source "
               f"where {WHERE_RUN} and type_diff = 'DIFF' order by object_name")

# --- Requetes de la synthese ---------------------------------------------------------------
RUN_INFO_SQL = (
    "select to_char(r.ts_exec at time zone 'Europe/Paris', 'YYYY-MM-DD HH24:MI:SS') as \"Date\", "
    "e.instance1 as \"Instance 1\", e.base1 as \"Base 1\", e.instance2 as \"Instance 2\", e.base2 as \"Base 2\", "
    "r.statut as \"Statut\", coalesce(r.message, '') as \"Message\" "
    "from compa_pg.run r join compa_pg.ref_execution e using (refid) "
    f"where r.run_id = {RUN_ID}"
)
SYNTHESE_SQL = (
    "select m.module as \"Module\", m.libelle as \"Contrôle\", "
    "coalesce(sum(s.nb), 0)::int as \"Écarts\", "
    "coalesce(sum(s.nb) filter (where s.type_diff = 'ONLY_R1'), 0)::int as \"Seulement R1\", "
    "coalesce(sum(s.nb) filter (where s.type_diff = 'ONLY_R2'), 0)::int as \"Seulement R2\", "
    "coalesce(sum(s.nb) filter (where s.type_diff = 'DIFF'), 0)::int as \"Différents\", "
    "coalesce(sum(s.nb) filter (where s.attendu), 0)::int as \"dont attendus\" "
    "from (values (1, 'inst_config', 'Configuration du cluster'), (2, 'db_size', 'Taille de la base'), "
    "(3, 'db_options', 'Options de la base'), (4, 'obj_tables', 'Structure des tables'), "
    "(5, 'obj_indexes', 'Index'), (6, 'obj_code', 'Vues, fonctions, triggers'), "
    "(7, 'obj_source', 'Code source'), (8, 'constraints', 'Contraintes et clés étrangères'), "
    "(9, 'extensions', 'Extensions'), (10, 'sequences', 'Séquences'), (11, 'roles', 'Rôles'), "
    "(12, 'grants', 'Droits')) as m(ord, module, libelle) "
    f"left join compa_pg.v_synthese_run s on s.module = m.module and s.run_id = {RUN_ID} "
    "group by m.ord, m.module, m.libelle order by m.ord"
)
HISTORY_SQL = (
    "select r.run_id as \"Run\", to_char(r.ts_exec at time zone 'Europe/Paris', 'YYYY-MM-DD HH24:MI:SS') as \"Date\", "
    "r.statut as \"Statut\", coalesce(sum(s.nb), 0)::int as \"Écarts\", "
    "coalesce(sum(s.nb) filter (where s.attendu), 0)::int as \"dont attendus\" "
    "from compa_pg.run r left join compa_pg.v_synthese_run s on s.run_id = r.run_id "
    f"where r.refid = (select refid from compa_pg.run where run_id = {RUN_ID}) "
    "group by r.run_id, r.ts_exec, r.statut order by r.ts_exec desc, r.run_id desc limit 20"
)

HELP_TEXT = """\
### Comment lire ces dashboards

- **R1** = instance 1 / base 1, **R2** = instance 2 / base 2 (voir le run en haut de page).
- **Seulement R1** : présent uniquement côté 1. **Seulement R2** : présent uniquement côté 2. **Différent** : présent des deux côtés avec des valeurs différentes (colonne *Champs en écart*).
- **Attendu** : écart connu, marqué par une règle de la table `compa_pg.exclusion_rules`.
- Choisir le **Run** dans la liste en haut : il est conservé quand on change de module avec la barre de liens (sous le titre) ou en cliquant sur un module du tableau ci-dessus.
- Les colonnes des tableaux sont filtrables et triables.
"""


# --- Briques Grafana ------------------------------------------------------------------------
class Ids:
    def __init__(self):
        self.n = 0

    def next(self):
        self.n += 1
        return self.n


def target(sql):
    return [{"datasource": DS, "editorMode": "code", "format": "table", "rawQuery": True, "rawSql": sql, "refId": "A"}]


def stat(ids, title, sql, x, w, color, description=None):
    p = {
        "id": ids.next(), "type": "stat", "title": title, "datasource": DS,
        "gridPos": {"h": 4, "w": w, "x": x, "y": 0},
        "targets": target(sql),
        "fieldConfig": {"defaults": {
            "color": {"mode": "thresholds"}, "noValue": "0", "unit": "none",
            "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": None}, {"color": color, "value": 1}]},
        }, "overrides": []},
        "options": {"colorMode": "background", "graphMode": "none", "justifyMode": "center", "orientation": "auto",
                    "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}, "textMode": "value"},
    }
    if description:
        p["description"] = description
    return p


def type_override():
    """Colore la colonne Type : bleu / violet / orange."""
    mapping = {
        "Seulement R1": {"color": "blue", "index": 0, "text": "Seulement R1"},
        "Seulement R2": {"color": "purple", "index": 1, "text": "Seulement R2"},
        "Différent": {"color": "orange", "index": 2, "text": "Différent"},
    }
    return {"matcher": {"id": "byName", "options": "Type"}, "properties": [
        {"id": "mappings", "value": [{"type": "value", "options": mapping}]},
        {"id": "custom.cellOptions", "value": {"type": "color-background"}},
        {"id": "custom.width", "value": 130},
    ]}


def attendu_override():
    return {"matcher": {"id": "byName", "options": "Attendu"}, "properties": [
        {"id": "custom.width", "value": 90},
        {"id": "mappings", "value": [{"type": "value", "options": {"Oui": {"color": "yellow", "index": 0, "text": "Oui"}}}]},
        {"id": "custom.cellOptions", "value": {"type": "color-text"}},
    ]}


def table(ids, title, sql, y, h, overrides=None, description=None, w=24):
    p = {
        "id": ids.next(), "type": "table", "title": title, "datasource": DS,
        "gridPos": {"h": h, "w": w, "x": 0, "y": y},
        "targets": target(sql),
        "fieldConfig": {"defaults": {
            "custom": {"align": "auto", "cellOptions": {"type": "auto"}, "filterable": True, "inspect": False},
            "mappings": [], "noValue": "",
            "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": None}]},
        }, "overrides": overrides or []},
        "options": {"cellHeight": "sm", "showHeader": True, "footer": {"show": False, "reducer": ["sum"], "fields": ""}},
    }
    if description:
        p["description"] = description
    return p


def text_panel(ids, content, y, h):
    return {"id": ids.next(), "type": "text", "title": "", "gridPos": {"h": h, "w": 24, "x": 0, "y": y},
            "options": {"mode": "markdown", "content": content, "code": {"language": "plaintext", "showLineNumbers": False,
                                                                           "showMiniMap": False}}}


def run_variable():
    return {"name": "run", "label": "Run", "type": "query", "datasource": DS,
            "description": "Run affiché : date | cluster1.base1 vs cluster2.base2",
            "definition": RUN_QUERY, "query": RUN_QUERY, "refresh": 1, "sort": 0, "multi": False,
            "includeAll": False, "hide": 0, "skipUrlSync": False, "options": [], "current": {}}


def nav_link():
    """Barre de liens vers tous les dashboards du projet ; includeVars conserve le run choisi."""
    return {"asDropdown": False, "icon": "external link", "includeVars": True, "keepTime": True,
            "tags": [TAG], "targetBlank": False, "title": "Modules", "tooltip": "Aller à un autre module",
            "type": "dashboards", "url": ""}


def dashboard(uid, title, description, panels, variables):
    return {
        "annotations": {"list": []}, "description": description, "editable": True, "fiscalYearStartMonth": 0,
        "graphTooltip": 0, "id": None, "links": [nav_link()], "liveNow": False, "panels": panels, "refresh": "",
        "schemaVersion": 39, "tags": [TAG], "templating": {"list": variables},
        "time": {"from": "now-6h", "to": "now"}, "timepicker": {"hidden": True}, "timezone": "browser",
        "title": title, "uid": uid, "version": 1, "weekStart": "",
    }


# --- Dashboards -----------------------------------------------------------------------------
def stats_row(ids, table_name):
    t = f"compa_pg.{table_name}"
    base = f"select count(*) as \"Écarts\" from {t} where {WHERE_RUN}"
    return [
        stat(ids, "Écarts", base, 0, 5, "red", "Nombre total d'écarts du run pour ce module"),
        stat(ids, "Seulement R1", base + " and type_diff = 'ONLY_R1'", 5, 5, "blue", "Présents uniquement côté 1"),
        stat(ids, "Seulement R2", base + " and type_diff = 'ONLY_R2'", 10, 5, "purple", "Présents uniquement côté 2"),
        stat(ids, "Différents", base + " and type_diff = 'DIFF'", 15, 5, "orange", "Présents des deux côtés, valeurs différentes"),
        stat(ids, "Dont attendus", base + " and attendu", 20, 4, "yellow", "Écarts marqués attendus par exclusion_rules"),
    ]


def module_dashboard(key, uid, title, table_name):
    ids = Ids()
    descriptions = {
        "inst_config": "Paramètres du serveur (pg_settings) ; seule la valeur déclenche un écart. Port, répertoires et search_path sont exclus.",
        "db_size": "Taille de la base et de chaque schéma (Mo).",
        "db_options": "Options de la base (propriétaire, encodage, collation, limite de connexions) et réglages ALTER DATABASE SET.",
        "obj_tables": "Structure des tables : colonnes, types, nullabilité, valeur par défaut, identity.",
        "obj_indexes": "Index : unicité, clé primaire, méthode, colonnes et prédicat (définition).",
        "obj_code": "Présence des vues, vues matérialisées, fonctions, procédures et triggers.",
        "obj_source": "Code source des vues, fonctions, procédures et triggers (comparé par hash).",
        "constraints": "Contraintes : clés primaires, étrangères (actions ON DELETE/UPDATE), uniques, CHECK, exclusion.",
        "extensions": "Extensions installées et leur version.",
        "sequences": "Paramètres des séquences (la valeur courante n'est pas comparée).",
        "roles": "Rôles du cluster (hors pg_*) : attributs et appartenances.",
        "grants": "Droits explicites (ACL) sur la base, les schémas, tables, vues, séquences et fonctions.",
    }
    panels = stats_row(ids, table_name)
    variables = [run_variable()]
    if key == "obj_source":
        panels.append(table(ids, "Objets en écart", main_table_sql(key), 4, 9, [type_override(), attendu_override()]))
        variables += [
            {"name": "objet", "label": "Objet", "type": "query", "datasource": DS,
             "description": "Objet dont le code est comparé ligne à ligne (objets présents des deux côtés)",
             "definition": OBJET_QUERY, "query": OBJET_QUERY, "refresh": 1, "sort": 0, "multi": False,
             "includeAll": False, "hide": 0, "skipUrlSync": False, "options": [], "current": {}},
            {"name": "filtre", "label": "Lignes", "type": "custom", "description": "Lignes à afficher",
             "query": "Lignes différentes : diff,Toutes les lignes : toutes", "multi": False, "includeAll": False,
             "hide": 0, "skipUrlSync": False,
             "options": [{"selected": True, "text": "Lignes différentes", "value": "diff"},
                         {"selected": False, "text": "Toutes les lignes", "value": "toutes"}],
             "current": {"selected": True, "text": "Lignes différentes", "value": "diff"}},
        ]
        panels.append(table(
            ids, "Code source : ${objet:text}", SOURCE_LINES_SQL, 13, 16,
            [{"matcher": {"id": "byName", "options": "Ligne"}, "properties": [{"id": "custom.width", "value": 70}]},
             {"matcher": {"id": "byName", "options": "Écart"}, "properties": [
                 {"id": "custom.width", "value": 60}, {"id": "custom.cellOptions", "value": {"type": "color-text"}},
                 {"id": "color", "value": {"mode": "fixed", "fixedColor": "orange"}}]}],
            "Comparaison par position de ligne : une ligne insérée décale les suivantes. "
            "Choisir l'objet avec la liste « Objet » en haut."))
    else:
        panels.append(table(ids, "Écarts", main_table_sql(key), 4, 20, [type_override(), attendu_override()]))
    return dashboard(uid, title, descriptions[key] + " R1 = cluster 1 / base 1, R2 = cluster 2 / base 2.", panels, variables)


def home_dashboard():
    uid, title = HOME[1], HOME[2]
    ids = Ids()
    module_link = [{"title": "Ouvrir ce module", "url": "/d/compapg-${__data.fields.Module}?var-run=${run}&${__url_time_range}",
                    "targetBlank": False}]
    synth_overrides = [
        {"matcher": {"id": "byName", "options": "Module"}, "properties": [{"id": "links", "value": module_link}]},
        {"matcher": {"id": "byName", "options": "Écarts"}, "properties": [
            {"id": "custom.cellOptions", "value": {"type": "color-background"}},
            {"id": "thresholds", "value": {"mode": "absolute", "steps": [{"color": "green", "value": None},
                                                                            {"color": "orange", "value": 1}]}},
            {"id": "color", "value": {"mode": "thresholds"}}]},
    ]
    panels = [
        table(ids, "Run sélectionné", RUN_INFO_SQL, 0, 4),
        table(ids, "Écarts par module", SYNTHESE_SQL, 4, 9, synth_overrides,
              "Cliquer sur un nom de module pour ouvrir son dashboard avec le même run."),
        table(ids, "Historique de ce couple instance/base (20 derniers runs)", HISTORY_SQL, 13, 9),
        text_panel(ids, HELP_TEXT, 22, 8),
    ]
    return dashboard(uid, title, "Synthèse d'un run de comparaison : écarts par module et historique.", panels, [run_variable()])


def build():
    dashboards = {f"{HOME[1]}.json": home_dashboard()}
    for key, uid, title, table_name in MODULES:
        dashboards[f"{uid}.json"] = module_dashboard(key, uid, title, table_name)
    return dashboards


def render(d):
    return json.dumps(d, indent=2, ensure_ascii=False) + "\n"


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    for name, d in build().items():
        with open(os.path.join(OUT_DIR, name), "w", encoding="utf-8") as fh:
            fh.write(render(d))
    print(f"{len(build())} dashboards ecrits dans {OUT_DIR}")


if __name__ == "__main__":
    sys.exit(main())
