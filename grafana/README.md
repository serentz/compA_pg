# Grafana : dashboards Comparaison PostgreSQL

13 dashboards (synthèse + 12 modules), provisionnés par fichiers et versionnés en JSON.
Une barre de liens « Modules » (par tag `compa_pg`) permet de passer d'un module à l'autre en gardant le run sélectionné (`includeVars`).

| Dossier | Contenu |
|---|---|
| `build_dashboards.py` | Générateur des JSON (`python3 grafana/build_dashboards.py`) |
| `dashboards/` | JSON générés : `compapg-home`, `compapg-<module>` |
| `provisioning/` | Datasource et fournisseur de dashboards |
| `tests/` | Tests de structure et d'exécution des requêtes SQL |

Ne pas éditer les JSON à la main : modifier le générateur puis le relancer.

## Installation (pgbastion, Ubuntu)

1. Installer Grafana OSS selon la documentation officielle (dépôt apt grafana.com), puis `sudo systemctl enable --now grafana-server`.
2. Activer le rôle `grafana_ro` et lui définir un mot de passe (il est créé en `NOLOGIN`, sans mot de passe). Sur `pgdb01`, en `compa_app` : `psql -h 127.0.0.1 -U compa_app -d compa -c "ALTER ROLE grafana_ro LOGIN"` puis `\password grafana_ro` dans psql.
3. **Ajouter** (sans remplacer le fichier : il contient déjà les réglages par défaut de Grafana) les variables à la fin de `/etc/default/grafana-server`, non versionné. Mot de passe sans espace, `#` ni guillemet (fichier lu par systemd) :

```
COMPA_PG_HOST=pgdb01
COMPA_PG_PORT=5432
COMPA_PG_DB=compa
COMPA_PG_PASSWORD=<mot_de_passe_grafana_ro>
```

4. Copier les fichiers :

```
sudo cp grafana/provisioning/datasources/compa_pg.yaml /etc/grafana/provisioning/datasources/
sudo cp grafana/provisioning/dashboards/compa_pg.yaml  /etc/grafana/provisioning/dashboards/
sudo mkdir -p /var/lib/grafana/dashboards/compa_pg
sudo cp grafana/dashboards/*.json /var/lib/grafana/dashboards/compa_pg/
sudo chown -R grafana:grafana /var/lib/grafana/dashboards
sudo systemctl restart grafana-server
```

5. Dans Grafana : Connections > Data sources > « Comparaison PostgreSQL » > **Save & test**. PostgreSQL doit autoriser `grafana_ro` depuis le bastion (`pg_hba.conf`, `listen_addresses`).

## Utilisation

Ouvrir « 00 - Synthèse », choisir un run en haut, puis naviguer avec la barre « Modules ». Le tableau « Écarts par module » de la synthèse ouvre directement le module cliqué.

## Tests

```
python3 grafana/tests/test_dashboards.py                      # structure
COMPA_TEST_PG=1 COMPA_TEST_DB=compa python3 grafana/tests/test_dashboards.py   # + exécution des requêtes (PGHOST/PGUSER...)
```

Les JSON n'ont pas été validés dans un Grafana réel : vérifier visuellement au premier import.
