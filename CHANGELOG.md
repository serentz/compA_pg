# Changelog

## 0.2 - en cours (2026-10-18)

### Déploiement par archives
- Dossier `Deploy/` : 4 archives (`compa_pg_depot`, `compa_pg_comparateur`, `compa_pg_grafana`, `compa_pg_clusters_test`), chacune avec `install.sh`, `verify.sh`, `LISEZMOI.md` et `SHA256SUMS`. Voir `docs/deploiement_archives.md`.
- `packaging/build_packages.sh` (archives reproductibles) et `packaging/test_packages.sh` (installation réelle des 4 archives puis comparaison : 55 écarts).
- `infra/pg_clusters.sh` : scripts SQL lus par redirection (l'utilisateur `postgres` ne lisait pas un fichier sous `/home`) ; mot de passe via `COMPA_APP_PASSWORD`.

## 0.1 - en cours (2026-10-16)

Première version de compA_pg, portage de [comparaison_ase](https://github.com/serentz/comparaison_ase) 0.1 vers PostgreSQL.

### Contenu
- `bash/compa_pg.sh` : extraction par `psql --csv` de 12 modules sur deux cluster/base, appel de `compare.py`.
- 12 modules : `inst_config`, `db_size`, `db_options`, `obj_tables`, `obj_indexes`, `obj_code`, `obj_source`,
  `constraints`, `extensions`, `sequences`, `roles`, `grants`.
- `python/compare.py` : comparaison par clé, règles d'exclusion (`IGNORE` / `ATTENDU`), insertion transactionnelle.
- Schéma `compa_pg` : références, runs, `config_compa_pg`, `exclusion_rules`, 12 tables `diff_<module>`, vues Grafana, rôle `grafana_ro`.
- 13 dashboards Grafana générés (synthèse + 12 modules).
- Environnement de test : `infra/pg_clusters.sh` (deux clusters 5433/5434), bases `poc_pg` avec écarts volontaires (`sql/pg_test/`).

### Choix de conception
- Extraction avec `search_path = pg_catalog` : `pg_get_expr`, `pg_get_constraintdef`, `format_type`... qualifient alors toujours les noms, sinon deux bases à `search_path` différents produisent de faux écarts.
- CSV `psql --csv` avec séparateur `|` et champs entre guillemets si besoin : les définitions de contraintes et le code source peuvent contenir `|`, guillemets et retours à la ligne.
- Paramètres propres à un cluster (`port`, `data_directory`...) exclus à l'extraction plutôt que par règle.

### Limites
- Voir `README.md` (section « Limites connues »).
- Dashboards non encore ouverts dans un Grafana réel.
