# compA_pg : archive « clusters de test » ({{VERSION}})

**Pour le POC et la validation uniquement.** Crée deux clusters PostgreSQL de test sur la même machine, avec une base `poc_pg` dont les différences sont voulues, pour vérifier toute la chaîne (extraction, comparaison, dashboards) sans toucher à une vraie base.

| Cluster | Port | Rôle |
|---|---|---|
| `pga` | 5433 | cluster 1 (référence) |
| `pgb` | 5434 | cluster 2 (comparé) : écarts voulus, dont `work_mem` différent |

Machine du POC : `pgdb01`. Le résultat attendu d'une comparaison `PGA/poc_pg` contre `PGB/poc_pg` est de **55 écarts** (1 `inst_config`, 1 `db_size`, 1 `db_options`, 8 `obj_tables`, 5 `obj_indexes`, 3 `obj_code`, 5 `obj_source`, 5 `constraints`, 2 `extensions`, 1 `sequences`, 4 `roles`, 19 `grants`).

> ⚠ Ouverture réseau (`listen_addresses = '*'`) et superutilisateur de test `compa_app` : ne pas reproduire sur un vrai serveur.

## Contenu

| Fichier | Rôle |
|---|---|
| `install.sh`, `verify.sh` | création des clusters (rejouable) et contrôles |
| `infra/pg_clusters.sh` | script qui crée les clusters, le login `compa_app` et charge les bases |
| `sql/pg_test/01_*.sql`, `02_*.sql` | bases `poc_pg` des clusters 1 et 2 |
| `scripts/compa_pg.env.example` | facultatif : mot de passe de `compa_app`, réseau |
| `SHA256SUMS`, `VERSION` | contrôle d'intégrité, version |

## 1. Prérequis

Ubuntu avec `postgresql` installé (`sudo apt install -y postgresql`), `sudo`. Les ports 5433 et 5434 doivent être libres.

## 2. Installation

```bash
tar xzf compa_pg_clusters_test.tgz
cd compa_pg_clusters_test
sha256sum -c SHA256SUMS --quiet && echo "archive intacte"

sudo ./install.sh              # demande le mot de passe du login compa_app (8 caracteres minimum)
sudo ./verify.sh
```

Sans question : `cp scripts/compa_pg.env.example scripts/compa_pg.env`, renseigner `COMPA_APP_PASSWORD`, puis `sudo ./install.sh`. `COMPA_NET` (défaut `192.168.60.0/24`) est le réseau autorisé.

## 3. Équivalent à la main

```bash
sudo pg_createcluster 16 pga --port=5433 && sudo pg_createcluster 16 pgb --port=5434
# listen_addresses = '*' et ligne pg_hba « host all all <réseau> scram-sha-256 » dans /etc/postgresql/16/{pga,pgb}/
sudo pg_ctlcluster 16 pga start && sudo pg_ctlcluster 16 pgb start
sudo -u postgres psql -p 5433 -c "CREATE ROLE compa_app LOGIN SUPERUSER PASSWORD '<mdp>'"     # idem sur 5434
sudo -u postgres psql -p 5433 -d postgres -f sql/pg_test/01_create_poc_db_cluster1.sql
sudo -u postgres psql -p 5434 -d postgres -f sql/pg_test/02_create_poc_db_cluster2.sql
```

## 4. Faire la première comparaison

1. Sur la machine de l'archive depot : `sudo ./scripts/declarer-instance.sh PGA pgdb01 5433 compa_app` et `PGB ... 5434 compa_app` (même mot de passe).
2. Sur la machine du comparateur : `compa_pg -S PGA -D poc_pg -s PGB -d poc_pg -k`. Le script doit afficher 55 écarts.
3. Dans Grafana, « 00 - Synthèse » : choisir le run.

## 5. Planification

Aucune : ce sont deux clusters de test.

## 6. Désinstallation

```bash
sudo pg_dropcluster --stop 16 pga && sudo pg_dropcluster --stop 16 pgb
```

## 7. Dépannage

| Symptôme | Piste |
|---|---|
| « PostgreSQL xx absent » | `sudo apt install postgresql` puis relancer ; la version est celle de `/usr/lib/postgresql` |
| Port déjà utilisé | `pg_lsclusters` ; un autre cluster occupe 5433 ou 5434 |
| Connexion refusée depuis une autre machine | `COMPA_NET` ne contient pas l'IP de la machine ; relancer `install.sh` |
