# compA_pg : archive « comparateur » ({{VERSION}})

Installe sur la machine qui lance les comparaisons (`pgbastion`, 192.168.60.10) :

| Composant | Rôle |
|---|---|
| `compa_pg.sh` + 12 requêtes SQL | extrait avec `psql` la configuration, les objets, les droits des deux couples cluster/base |
| `compare.py` | compare les extractions et enregistre les écarts dans la base de résultats |
| commande `compa_pg` | lance une comparaison avec l'accès à la base de résultats déjà configuré |
| `compa_pg-planifie` | lance les comparaisons listées dans `/etc/compa_pg/planifie.conf` (timer systemd ou cron) |

À installer après l'archive `compa_pg_depot`.

## Contenu

| Fichier | Rôle |
|---|---|
| `install.sh`, `verify.sh` | installation (rejouable) et contrôles |
| `bash/compa_pg.sh`, `bash/queries/*.sql` | script d'orchestration et 12 requêtes d'extraction |
| `python/compare.py` | comparaison (bibliothèque standard Python, **aucun paquet pip** : pas de `manifeste.txt`) |
| `systemd/`, `cron/` | planification quotidienne : timer systemd, ou fichier cron équivalent |
| `scripts/` | `compa_pg-planifie.sh`, modèle `planifie.conf.example`, `compa_pg.env.example` |
| `SHA256SUMS`, `VERSION` | contrôle d'intégrité, version |

## 1. Prérequis

- Ubuntu Server 24.04, `sudo`, accès `apt` (paquets `postgresql-client` et `python3`).
- La base de résultats installée (archive depot) et joignable : IP, port, mot de passe de `compa_app`.
- Les clusters à comparer joignables depuis cette machine et déclarés dans `config_compa_pg` (voir l'archive depot, `declarer-instance.sh`).

## 2. Installation

```bash
tar xzf compa_pg_comparateur.tgz
cd compa_pg_comparateur
sha256sum -c SHA256SUMS --quiet && echo "archive intacte"

cp scripts/compa_pg.env.example scripts/compa_pg.env
nano scripts/compa_pg.env          # accès à la base de résultats

sudo ./install.sh
sudo ./verify.sh
```

### Paramètres (`scripts/compa_pg.env`)

| Variable | Rôle |
|---|---|
| `PG_HOST`, `PG_PORT`, `PG_DB` | base de résultats (`192.168.60.11`, 5432, `compa`) |
| `PG_USER`, `PG_PASSWORD` | login propriétaire (`compa_app`) et son mot de passe (celui de l'archive depot) |
| `INSTALL_DIR` | dossier des programmes (`/opt/compa_pg`) |
| `RUN_USER` | login Linux qui lance les comparaisons (vide : celui qui a lancé `sudo`). **Seul lui peut lire `/etc/compa_pg/compa_pg.env`** |
| `ENABLE_SCHEDULE` | `1` active le timer de comparaison quotidienne |

## 3. Ce que fait `install.sh`, et son équivalent à la main

**Composants**

```bash
sudo apt update && sudo apt install -y postgresql-client python3
```

**Programmes** (aucun venv, aucune dépendance)

```bash
sudo mkdir -p /opt/compa_pg/bash/queries /opt/compa_pg/python
sudo install -m 0755 bash/compa_pg.sh /opt/compa_pg/bash/ && sudo install -m 0644 bash/queries/*.sql /opt/compa_pg/bash/queries/
sudo install -m 0755 python/compare.py /opt/compa_pg/python/
```

**SQL** : aucun à exécuter ici. Le script lit la configuration des clusters comparés dans la base de résultats et y écrit les écarts.

**Utilisation**

```bash
compa_pg -S PGA -D poc_pg -s PGB -d poc_pg -k        # -k : conserve les CSV pour contrôle (premier run)
compa_pg -h                                          # aide
```

Équivalent sans la commande `compa_pg` : `PGPASSWORD=... /opt/compa_pg/bash/compa_pg.sh -S PGA -D poc_pg -s PGB -d poc_pg -U compa_app -H 192.168.60.11 -p 5432 -n compa`. Liste de contrôle de première exécution et interprétation des écarts : `docs/premiere_execution.md` du dépôt compA_pg.

## 4. Planification (systemd, ou cron)

Les comparaisons à planifier sont listées dans `/etc/compa_pg/planifie.conf` (une ligne par comparaison : `INSTANCE1 BASE1 INSTANCE2 BASE2`) :

```
PGA poc_pg PGB poc_pg
```

**Timer systemd** : tous les jours à 02:30. `install.sh` l'installe et l'active si `ENABLE_SCHEDULE=1`. À la main :

```bash
sudo cp systemd/compa_pg-planifie.service systemd/compa_pg-planifie.timer /etc/systemd/system/
sudo sed -i 's/^User=.*/User=<RUN_USER>/' /etc/systemd/system/compa_pg-planifie.service
sudo systemctl daemon-reload && sudo systemctl enable --now compa_pg-planifie.timer
systemctl list-timers 'compa_pg-*'          # prochaine exécution
journalctl -u compa_pg-planifie -n 20       # dernière exécution
```

**Équivalent cron** (à la place du timer, jamais en plus) :

```bash
sudo sed 's/RUN_USER/<login>/' cron/compa_pg.cron | sudo tee /etc/cron.d/compa_pg
```

soit la ligne : `30 2 * * * <login> /usr/local/bin/compa_pg-planifie 2>&1 | logger -t compa_pg-planifie`.

## 5. Mise à jour et désinstallation

- **Mise à jour** : extraire la nouvelle archive, recopier `scripts/compa_pg.env`, relancer `sudo ./install.sh`.
- **Désinstallation** :

```bash
sudo systemctl disable --now compa_pg-planifie.timer 2>/dev/null
sudo rm -f /etc/systemd/system/compa_pg-planifie.* /etc/cron.d/compa_pg /usr/local/bin/compa_pg /usr/local/bin/compa_pg-planifie
sudo rm -r /opt/compa_pg /etc/compa_pg && sudo systemctl daemon-reload
```

## 6. Dépannage

| Symptôme | Piste |
|---|---|
| `compa_pg` : « illisible (réservé à ... ) » | lancer la commande avec le login `RUN_USER` |
| Code retour 10 | outil manquant ou base de résultats injoignable (`verify.sh`) |
| Code retour 11 | schéma absent : relancer `install.sh` de l'archive depot |
| Code retour 12 | instance absente de `config_compa_pg` : `declarer-instance.sh` |
| Code retour 13 | connexion à un cluster comparé en échec : hôte, port, login, `pg_hba.conf` du cluster |
