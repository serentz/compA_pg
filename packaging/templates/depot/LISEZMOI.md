# compA_pg : archive « depot » ({{VERSION}})

Installe la **base de résultats** : PostgreSQL, la base `compa` et le schéma `compa_pg` (références, runs, configuration des clusters, règles d'exclusion, 12 tables `diff_<module>`, vues Grafana). C'est là que le comparateur écrit et que Grafana lit.

À installer **en premier**. Machine du POC : `pgdb01` (192.168.60.11).

## Contenu

| Fichier | Rôle |
|---|---|
| `install.sh` | installation complète (rejouable) |
| `verify.sh` | contrôles après installation |
| `sql/create_schema.sql` | schéma `compa_pg` (rejouable sans perte de données) |
| `scripts/declarer-instance.sh` | déclare un cluster à comparer dans `compa_pg.config_compa_pg` |
| `scripts/compa_pg.env.example` | paramètres à copier en `compa_pg.env` |
| `SHA256SUMS`, `VERSION` | contrôle d'intégrité, version |

## 1. Prérequis

- Ubuntu Server 24.04 (ou Debian), accès à `apt`, un compte avec `sudo`.
- Les IP du réseau : le comparateur et Grafana doivent joindre cette machine sur le port PostgreSQL (`ALLOW_SUBNET`).

## 2. Installation

```bash
tar xzf compa_pg_depot.tgz
cd compa_pg_depot
sha256sum -c SHA256SUMS --quiet && echo "archive intacte"

cp scripts/compa_pg.env.example scripts/compa_pg.env
nano scripts/compa_pg.env          # mots de passe, réseau

sudo ./install.sh
sudo ./verify.sh
```

### Paramètres (`scripts/compa_pg.env`)

| Variable | Rôle |
|---|---|
| `PG_PORT` | port du cluster qui héberge la base (5432) |
| `DEPOT_DB`, `DEPOT_OWNER` | nom de la base (`compa`) et login propriétaire (`compa_app`), utilisé par le comparateur |
| `DEPOT_OWNER_PASSWORD` | mot de passe de ce login (à reprendre dans l'archive comparateur) |
| `GRAFANA_RO_PASSWORD` | mot de passe de `grafana_ro`, lecture seule (à reprendre dans l'archive grafana) |
| `ALLOW_SUBNET` | réseau autorisé à joindre la base (`192.168.60.0/24`) |

Mots de passe : 8 caractères minimum, lettres, chiffres et `. _ @ % + = -` seulement.

## 3. Ce que fait `install.sh`, et son équivalent à la main

**Composants**

```bash
sudo apt update && sudo apt install -y postgresql
```

**Réseau PostgreSQL** (version 16, cluster `main` ; adapter) :

```bash
echo "listen_addresses = '*'" | sudo tee /etc/postgresql/16/main/conf.d/compa_pg.conf
echo "host compa compa_app 192.168.60.0/24 scram-sha-256" | sudo tee -a /etc/postgresql/16/main/pg_hba.conf
echo "host compa grafana_ro 192.168.60.0/24 scram-sha-256" | sudo tee -a /etc/postgresql/16/main/pg_hba.conf
sudo systemctl restart postgresql
```

**SQL** : login, base, schéma, rôle Grafana.

```bash
sudo -u postgres psql -c "CREATE ROLE compa_app LOGIN CREATEROLE PASSWORD '<mdp>'"
sudo -u postgres psql -c "CREATE DATABASE compa OWNER compa_app"
PGOPTIONS="-c role=compa_app" sudo -E -u postgres psql -d compa < sql/create_schema.sql    # le « < » est voulu : postgres ne lit pas /home
sudo -u postgres psql -d compa -c "ALTER ROLE grafana_ro LOGIN PASSWORD '<mdp>'"
```

## 4. Déclarer les clusters à comparer

Chaque cluster comparé est enregistré sous un nom (`PGA`, `PGB`...) avec son login, utilisé ensuite avec `-S` et `-s`. Le mot de passe est lu dans `INSTANCE_PASSWORD` ou demandé :

```bash
sudo ./scripts/declarer-instance.sh PGA pgdb01 5433 compa_app "cluster de test 1"
sudo ./scripts/declarer-instance.sh PGB pgdb01 5434 compa_app "cluster de test 2"
```

`config_compa_pg` contient des mots de passe en clair : jamais lisible par `grafana_ro`, jamais versionné.

## 5. Planification

Rien à planifier ici : ce sont des tables PostgreSQL. Les comparaisons se planifient sur la machine du comparateur (archive `compa_pg_comparateur`). Pour sauvegarder les résultats : `sudo -u postgres pg_dump -Fc compa > compa.dump`.

## 6. Mise à jour et désinstallation

- **Mise à jour** : extraire la nouvelle archive, recopier `scripts/compa_pg.env`, relancer `sudo ./install.sh` : le schéma est rejoué sans perte de données.
- **Désinstallation** (⚠ détruit les résultats) : `sudo -u postgres psql -c "DROP DATABASE compa"`, puis `DROP ROLE compa_app; DROP ROLE grafana_ro;`, et retirer les lignes ajoutées à `conf.d/compa_pg.conf` et `pg_hba.conf` (bloc `COMPA_PG depot`).

## 7. Dépannage

| Symptôme | Piste |
|---|---|
| « Aucun cluster PostgreSQL n'écoute sur le port » | `pg_lsclusters` ; adapter `PG_PORT` |
| Le comparateur ne se connecte pas | `ALLOW_SUBNET`, pare-feu, `sudo -u postgres psql -c "SHOW listen_addresses"` doit donner `*` |
| `verify.sh` : « 17 tables » en échec | relancer `install.sh` et lire les erreurs SQL |
