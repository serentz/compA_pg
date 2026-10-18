# compA_pg : archive « grafana » ({{VERSION}})

Installe Grafana et les **13 dashboards** de compA_pg (synthèse + un par module), avec la source de données « Comparaison PostgreSQL » provisionnée par fichiers (aucun mot de passe dans les fichiers versionnés). Machine du POC : `pgbastion` (192.168.60.10).

À installer après l'archive `compa_pg_depot`. Aucun plugin Grafana requis.

## Contenu

| Fichier | Rôle |
|---|---|
| `install.sh`, `verify.sh` | installation (rejouable) et contrôles |
| `dashboards/compapg-*.json` | les 13 dashboards (`compapg-home` = « 00 - Synthèse », puis un par module) |
| `provisioning/datasources/compa_pg.yaml` | source de données `grafana_ro` (variables `COMPA_PG_*`) |
| `provisioning/dashboards/compa_pg.yaml` | fournisseur de dashboards (dossier « Comparaison PostgreSQL ») |
| `scripts/compa_pg.env.example` | paramètres à copier en `compa_pg.env` |
| `SHA256SUMS`, `VERSION` | contrôle d'intégrité, version |

## 1. Prérequis

- Ubuntu Server 24.04, `sudo`, accès Internet (`apt.grafana.com`).
- La base de résultats installée et joignable sur son port depuis cette machine (`ALLOW_SUBNET` de l'archive depot), mot de passe de `grafana_ro` connu.

## 2. Installation

```bash
tar xzf compa_pg_grafana.tgz
cd compa_pg_grafana
sha256sum -c SHA256SUMS --quiet && echo "archive intacte"

cp scripts/compa_pg.env.example scripts/compa_pg.env
nano scripts/compa_pg.env          # accès à la base de résultats

sudo ./install.sh
sudo ./verify.sh
```

### Paramètres (`scripts/compa_pg.env`)

| Variable | Rôle |
|---|---|
| `COMPA_PG_HOST`, `COMPA_PG_PORT`, `COMPA_PG_DB` | base de résultats (`192.168.60.11`, 5432, `compa`) |
| `COMPA_PG_PASSWORD` | mot de passe de `grafana_ro` (`GRAFANA_RO_PASSWORD` de l'archive depot) |
| `GRAFANA_ADMIN_PASSWORD` | facultatif : permet à `verify.sh` de tester la source de données et les dashboards dans Grafana |

## 3. Ce que fait `install.sh`, et son équivalent à la main

**Composants**

```bash
sudo apt install -y apt-transport-https software-properties-common wget gnupg curl
wget -q -O - https://apt.grafana.com/gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/grafana.gpg
echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" | sudo tee /etc/apt/sources.list.d/grafana.list
sudo apt update && sudo apt install -y grafana
```

**SQL** : aucun. Les dashboards interrogent la base de résultats en direct, avec le rôle `grafana_ro` (lecture seule, jamais `config_compa_pg`).

**Variables de la source de données** : à **ajouter** à la fin de `/etc/default/grafana-server` (sans remplacer le fichier). Mot de passe sans espace, `#` ni guillemet :

```
COMPA_PG_HOST=192.168.60.11
COMPA_PG_PORT=5432
COMPA_PG_DB=compa
COMPA_PG_PASSWORD=<mot de passe de grafana_ro>
```

**Fichiers et démarrage**

```bash
sudo cp provisioning/datasources/compa_pg.yaml /etc/grafana/provisioning/datasources/
sudo cp provisioning/dashboards/compa_pg.yaml  /etc/grafana/provisioning/dashboards/
sudo mkdir -p /var/lib/grafana/dashboards/compa_pg
sudo cp dashboards/*.json /var/lib/grafana/dashboards/compa_pg/
sudo chown -R grafana:grafana /var/lib/grafana/dashboards
sudo systemctl enable --now grafana-server && sudo systemctl restart grafana-server
```

## 4. Planification

Aucune : Grafana tourne en service (`grafana-server`), les dashboards lisent la base à l'ouverture. Dashboards rechargés depuis les fichiers toutes les 30 s.

## 5. Utilisation

Ouvrir `http://<ip>:3000` (compte `admin` / mot de passe `admin` la première fois : Grafana demande de le changer), dossier **Comparaison PostgreSQL**, dashboard « 00 - Synthèse » : choisir un run en haut, puis naviguer avec la barre « Modules ». Si les panneaux restent vides : *Connections > Data sources > Comparaison PostgreSQL > Save & test*.

## 6. Mise à jour et désinstallation

- **Mise à jour** : nouvelle archive, recopier `scripts/compa_pg.env`, relancer `sudo ./install.sh` (les dashboards sont remplacés ; ne pas les modifier dans l'interface, les modifications seraient écrasées).
- **Désinstallation** : `sudo rm -r /var/lib/grafana/dashboards/compa_pg /etc/grafana/provisioning/*/compa_pg.yaml`, retirer le bloc `COMPA_PG env` de `/etc/default/grafana-server`, `sudo systemctl restart grafana-server`.

## 7. Dépannage

| Symptôme | Piste |
|---|---|
| Panneaux vides, « Save & test » en échec | mot de passe de `grafana_ro`, `ALLOW_SUBNET` côté depot, `COMPA_PG_HOST` ; relancer `verify.sh` |
| Grafana plus ancien que 10.3 | dans `compa_pg.yaml` de la source de données, remplacer le type `grafana-postgresql-datasource` par `postgres` |
| Dashboards absents | attendre 30 s, `journalctl -u grafana-server`, droits du dossier (`grafana:grafana`) |
