# compA_pg

Compare deux couples **cluster / base de données** PostgreSQL et montre les écarts dans Grafana.

Projet frère de [`comparaison_ase`](https://github.com/serentz/comparaison_ase) (même architecture, appliquée à SAP ASE).

Pour chaque comparaison, un script extrait avec `psql` la configuration, la taille, les options, les tables,
les index, le code (vues, fonctions, procédures, triggers), les contraintes et clés étrangères, les extensions,
les séquences, les rôles et les droits des deux côtés. Un programme Python compare les extractions et enregistre
les différences dans PostgreSQL. Grafana les affiche : une synthèse, puis un dashboard par module, avec le détail
ligne à ligne du code source.

> **Statut : POC, version 0.1** ([`CHANGELOG.md`](CHANGELOG.md)). Validé de bout en bout sur deux clusters
> PostgreSQL 16 de test. Les dashboards Grafana ont leurs requêtes testées sur PostgreSQL mais n'ont pas encore
> été ouverts dans un Grafana réel : vérifier visuellement au premier import. Lis le code et les limites connues
> avant de l'utiliser sur des bases importantes.

## Comment ça marche

```
 cluster 1 ──┐                                                       ┌── Grafana
             ├── psql ──> CSV ──> compare.py ──> PostgreSQL ─────────┤   (synthèse + 12 dashboards)
 cluster 2 ──┘   (bash/compa_pg.sh)         (schéma compa_pg)        └── historique des runs
```

- **Extraction** (`bash/`) : `psql --csv` exécute les requêtes de `bash/queries/` sur chaque cluster, avec `search_path = pg_catalog` (noms toujours qualifiés : pas de faux écarts dus au `search_path` des bases). Le mot de passe est transmis par `PGPASSWORD` au seul processus `psql`, jamais en argument.
- **Comparaison** (`python/compare.py`) : bibliothèque standard Python 3.8+ uniquement, enregistrement via `psql`. Écarts typés `ONLY_R1`, `ONLY_R2` ou `DIFF`, avec règles d'exclusion pour le bruit connu.
- **Stockage** (`sql/postgres/`) : schéma `compa_pg`, historique de tous les runs.
- **Affichage** (`grafana/`) : 13 dashboards générés et provisionnés, navigation entre modules.

Les clusters comparés et la base de résultats sont indépendants : les résultats peuvent être stockés dans un troisième cluster (cas du POC : `pgdb01` port 5432).

## Modules comparés (12)

| Module | Contenu | Clé |
|---|---|---|
| `inst_config` | Paramètres du serveur (`pg_settings`) | nom |
| `db_size` | Taille de la base et de chaque schéma | élément |
| `db_options` | Propriétaire, encodage, collation, limite de connexions, `ALTER DATABASE SET` | option |
| `obj_tables` | Colonnes : type, `NOT NULL`, défaut, identity, colonne générée | table + colonne |
| `obj_indexes` | Index : unicité, clé primaire, méthode, colonnes, prédicat | table + index |
| `obj_code` | Présence des vues, vues matérialisées, fonctions, procédures, triggers | objet + type |
| `obj_source` | Code source des mêmes objets (comparé par empreinte MD5) | objet + type |
| `constraints` | Clés primaires, étrangères (actions `ON DELETE/UPDATE`), uniques, `CHECK`, exclusion | table + contrainte |
| `extensions` | Extensions installées et leur version | extension |
| `sequences` | Paramètres des séquences (pas la valeur courante) | séquence |
| `roles` | Rôles du cluster (hors `pg_*`) : attributs et appartenances | rôle |
| `grants` | Droits explicites (ACL) sur base, schémas, tables, vues, séquences, fonctions | type + objet + bénéficiaire |

Exclus volontairement de `inst_config` : `port`, `data_directory`, `config_file`, `hba_file`, `ident_file`, `external_pid_file`, `unix_socket_directories`, `cluster_name`, `log_directory`, `archive_command`, `application_name`, `search_path`, `lc_*` (propres à chaque cluster ou à la session). Adapter `bash/queries/inst_config.sql` si besoin.

## Prérequis

| Élément | Version |
|---|---|
| PostgreSQL (clusters comparés et base de résultats) | 12 ou plus (testé : 16) |
| `psql` | Sur la machine qui lance le script |
| Python | 3.8 ou plus, sans dépendance pip |
| Grafana OSS | Version récente |

Le login utilisé sur les clusters comparés doit pouvoir lire les catalogues (`pg_catalog`, accessibles à tout rôle) ;
pour que `roles` et `grants` soient complets il n'a besoin d'aucun droit particulier. `pg_get_functiondef` échoue
sur les fonctions d'agrégat : elles sont exclues (`prokind in ('f','p')`).

## Contenu du dépôt

| Dossier | Contenu |
|---|---|
| `bash/` | `compa_pg.sh` (orchestration), `queries/*.sql` (12 requêtes d'extraction), `tests/test_compa_pg.sh` |
| `python/` | `compare.py` et `tests/` (tests automatisés, CSV réels de deux clusters de test, `make_fixtures.sh`) |
| `sql/postgres/` | `create_schema.sql` : schéma `compa_pg` (références, runs, configuration, exclusions, 12 tables `diff_<module>`, vues Grafana) |
| `sql/pg_test/` | Deux scripts créant la base `poc_pg` avec des écarts volontaires (cluster 1 et cluster 2) |
| `Deploy/` | **Les 4 archives de déploiement** (`compa_pg_depot`, `compa_pg_comparateur`, `compa_pg_grafana`, `compa_pg_clusters_test`) et leurs empreintes |
| `packaging/` | `build_packages.sh` : construit les archives de `Deploy/` ; `test_packages.sh` ; modèles des LISEZMOI (voir `docs/deploiement_archives.md`) |
| `infra/` | `hyperv/create_vms.ps1` : réseau et 2 VM Hyper-V (guide : `docs/installation_vm.md`) ; `pg_clusters.sh` : crée les deux clusters de test (5433/5434) sur `pgdb01` |
| `grafana/` | 13 dashboards JSON, générateur, provisioning, tests. Voir `grafana/README.md` |
| `docs/` | Format des CSV, liste de contrôle de première exécution |

## Le dossier Deploy : archives de déploiement

`Deploy/` contient **les fichiers à copier sur les machines**, prêts à l'emploi : une archive par fonction. On n'a plus besoin de cloner le dépôt sur les VM.

| Archive | À installer sur | Rôle | Ordre |
|---|---|---|---|
| `compa_pg_depot.tgz` | la machine PostgreSQL (`pgdb01`) | PostgreSQL, base `compa`, schéma `compa_pg`, rôle Grafana lecture seule ; `declarer-instance.sh` déclare les clusters à comparer | 1 |
| `compa_pg_clusters_test.tgz` | la même machine (POC uniquement) | 2 clusters de test (5433, 5434) avec écarts voulus : 55 écarts attendus | 2 (option) |
| `compa_pg_comparateur.tgz` | la machine qui lance les comparaisons (`pgbastion`) | `compa_pg.sh`, 12 requêtes, `compare.py`, commande `compa_pg`, comparaison quotidienne planifiée (systemd ou cron) | 3 |
| `compa_pg_grafana.tgz` | `pgbastion` ou une autre machine | Grafana, source de données, 13 dashboards | 4 |

Chaque archive contient, à l'intérieur de son dossier :

- `LISEZMOI.md` : composants à installer, SQL à exécuter, planification (systemd et cron), vérification, mise à jour, désinstallation, dépannage ;
- `install.sh` et `verify.sh` : installation (rejouable) et contrôles ;
- `scripts/compa_pg.env.example` : paramètres à copier en `compa_pg.env` (IP, mots de passe) ;
- `SHA256SUMS` et `VERSION` : contrôle d'intégrité, version.

Pas de `manifeste.txt` Python : `compare.py` n'utilise que la bibliothèque standard (aucun paquet pip). `Deploy/SHA256SUMS` donne les empreintes des archives.

**Utilisation, sur chaque machine** (dans l'ordre du tableau) :

```powershell
# depuis Windows, après git pull
scp Deploy\compa_pg_depot.tgz admin01@192.168.60.11:~/
```

```bash
tar xzf compa_pg_depot.tgz && cd compa_pg_depot
sha256sum -c SHA256SUMS --quiet                    # contrôle d'intégrité
cp scripts/compa_pg.env.example scripts/compa_pg.env && nano scripts/compa_pg.env
sudo ./install.sh
sudo ./verify.sh
```

Les mots de passe de `compa_app` et de `grafana_ro` doivent être **identiques** dans les archives qui les partagent. Ensuite : `compa_pg -S PGA -D poc_pg -s PGB -d poc_pg -k`.

**Régénérer les archives** (après une modification du code, des requêtes ou des dashboards) : `packaging/build_packages.sh v0.2`, puis commiter `Deploy/`. Les fichiers de `Deploy/` sont générés : ne pas les modifier à la main. Détails et tests : [`docs/deploiement_archives.md`](docs/deploiement_archives.md).

> Statut : écrit le 2026-10-18, **à valider sur des VM neuves**. Testé en local : installation réelle des 4 archives suivie d'une comparaison (55 écarts).

## Mise en place

1. **Base de résultats** (une fois) :

```
createdb -h <hote> -U <login> compa
psql -h <hote> -U <login> -d compa -f sql/postgres/create_schema.sql
psql -h <hote> -U <login> -d compa -c "ALTER ROLE grafana_ro LOGIN PASSWORD '<a_definir>'"
```

Le script est rejouable sans perte de données. `grafana_ro` (lecture seule) est créé sans mot de passe : à définir, sans le versionner. Le schéma `compa_pg` peut cohabiter avec `compa_ase` dans la même base.

2. **Clusters de test** (optionnel, sur `pgdb01`) : `sudo bash infra/pg_clusters.sh`.

3. **Déclarer les clusters comparés** (un login par instance) :

```sql
INSERT INTO compa_pg.config_compa_pg (instance, host, port, login, password)
VALUES ('PGA', 'pgdb01', 5433, '<login>', '<mot_de_passe>'),
       ('PGB', 'pgdb01', 5434, '<login>', '<mot_de_passe>');
```

## Lancer une comparaison

```
export PGPASSWORD=<mot_de_passe_base_resultats>
bash/compa_pg.sh -S PGA -D poc_pg -s PGB -d poc_pg -U <login_pg> -H <hote_pg> -p 5432 -n compa
```

| Option | Rôle |
|---|---|
| `-S` `-D` | Instance (nom dans `config_compa_pg`) et base 1 |
| `-s` `-d` | Instance et base 2 |
| `-U` `-P` | Login et mot de passe de la base de résultats (`-P` est visible dans `ps`, préférer `PGPASSWORD`) |
| `-H` `-p` `-n` | Hôte, port et nom de la base de résultats |
| `-k` | Conserver les CSV du run |

Le script vérifie le schéma, lit les accès dans `config_compa_pg`, teste la connexion aux deux bases, crée ou retrouve le `refid`, ouvre un `run_id`, extrait les 12 modules des deux côtés, puis appelle `python/compare.py`. Comparer deux bases d'un même cluster est possible (deux instances déclarées vers le même hôte et port, ou la même instance avec deux bases).

| Code retour | Signification |
|---|---|
| 0 | Comparaison terminée |
| 1 | Arguments invalides |
| 2 | CSV invalide (retour de `compare.py`) |
| 3 | Erreur PostgreSQL (retour de `compare.py`) |
| 10 | Outil manquant ou base de résultats injoignable |
| 11 | Schéma ou tables absents : exécuter `sql/postgres/create_schema.sql` |
| 12 | Instance absente de `config_compa_pg` |
| 13 | Connexion ou extraction sur un cluster comparé en échec |

## Tests

```
# compare.py seul (les 55 écarts des clusters de test)
cd python && python3 compare.py --csv-dir tests/fixtures --dry-run -v
python3 -m unittest discover -s tests -v

# avec une base de résultats (schéma créé) : tests d'intégration PostgreSQL
COMPA_TEST_PG=1 PGHOST=<hote> PGUSER=<login> COMPA_TEST_DB=compa python3 -m unittest discover -s tests
COMPA_TEST_PG=1 COMPA_TEST_DB=compa python3 grafana/tests/test_dashboards.py

# script bash complet sur deux clusters de test (voir l'en-tête du fichier pour les variables)
bash/tests/test_compa_pg.sh
```

Les CSV de `python/tests/fixtures` sont une extraction réelle des deux clusters de test, régénérable avec `python/tests/make_fixtures.sh`.

## Limites connues

- Les valeurs courantes des séquences, les statistiques et les données des tables ne sont pas comparées.
- Les droits par défaut (`ALTER DEFAULT PRIVILEGES`), les politiques RLS, les types, domaines, règles et publications ne sont pas extraits.
- Les tailles (`db_size`) varient avec les données et le bloat : à lire comme un ordre de grandeur.
- Le code source est comparé après normalisation des fins de ligne et espaces de fin de ligne ; un changement de commentaire est un écart.
- Dans le tableau de code source, la comparaison ligne à ligne se fait par position : une ligne insérée décale les suivantes.

## Documentation

- [`docs/installation_vm.md`](docs/installation_vm.md) : création des 2 VM Hyper-V et installation de PostgreSQL, Python et Grafana
- [`docs/format_csv.md`](docs/format_csv.md) : format des CSV produits par le script et lus par `compare.py`, règles d'exclusion
- [`docs/premiere_execution.md`](docs/premiere_execution.md) : liste de contrôle avant une première exécution sur un nouvel environnement
- [`grafana/README.md`](grafana/README.md) : installation et utilisation des dashboards
- [`docs/deploiement_archives.md`](docs/deploiement_archives.md) : déploiement par archives (`Deploy/`)

## Sécurité

Aucun mot de passe ni fichier de configuration sensible ne doit être versionné. Les accès aux clusters comparés sont
lus dans la table `config_compa_pg` (mots de passe en clair : accès limité au rôle du script, jamais lisible par `grafana_ro`).

## Licence

[MIT](LICENSE) © Thierry SILSKI. Le logiciel est fourni sans garantie : teste-le sur des bases de test avant tout usage ailleurs.

PostgreSQL est une marque de la PostgreSQL Community Association of Canada ; projet indépendant, non affilié.
Ce dépôt ne contient que des fichiers de configuration, des requêtes et du code écrits pour ce projet.
