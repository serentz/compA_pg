# Déploiement par archives

> **Statut : écrit le 2026-10-18, à valider sur VM neuves.** Testé en local : construction reproductible, contenu des archives, syntaxe des scripts, et **installation réelle des 4 archives suivie d'une comparaison** (cluster temporaire, clusters de test, 55 écarts attendus, comparaison planifiée, dashboards copiés avec un Grafana simulé). **Non testé** : l'installation des paquets `apt` (PostgreSQL, Grafana), systemd, l'ouverture des dashboards dans un Grafana réel.

Au lieu de cloner le dépôt sur chaque VM, on dépose **une archive par fonction** (dossier `Deploy/`). Chaque archive contient ses scripts `install.sh` et `verify.sh`, un `LISEZMOI.md` (composants, SQL, planification systemd et cron, vérification, mise à jour, désinstallation, dépannage) et `SHA256SUMS`.

| Archive | Machine du POC | Contenu |
|---|---|---|
| `compa_pg_depot.tgz` | `pgdb01` | PostgreSQL, base `compa`, schéma `compa_pg`, rôle Grafana, déclaration des clusters à comparer |
| `compa_pg_comparateur.tgz` | `pgbastion` | `compa_pg.sh`, 12 requêtes, `compare.py`, commande `compa_pg`, comparaison planifiée (timer systemd ou cron) |
| `compa_pg_grafana.tgz` | `pgbastion` | Grafana, source de données, 13 dashboards |
| `compa_pg_clusters_test.tgz` | `pgdb01` | 2 clusters de test (5433, 5434) avec écarts voulus : **POC uniquement** |

Pas de `manifeste.txt` ici : `compare.py` n'utilise que la bibliothèque standard Python (aucun venv, aucun paquet pip).

## Ordre d'installation

1. `compa_pg_depot` sur la machine PostgreSQL ;
2. (POC) `compa_pg_clusters_test` sur la même machine, puis `declarer-instance.sh PGA ...` et `PGB ...` (voir le LISEZMOI du dépôt de résultats) ;
3. `compa_pg_comparateur` sur la machine qui lance les comparaisons ;
4. `compa_pg_grafana` (même machine ou autre).

Sur chaque machine : `tar xzf`, `cp scripts/compa_pg.env.example scripts/compa_pg.env`, éditer, `sudo ./install.sh`, `sudo ./verify.sh`. Les mots de passe (`compa_app`, `grafana_ro`) doivent être **identiques** dans les archives qui les partagent.

## Construire les archives

```bash
packaging/build_packages.sh v0.2        # -> Deploy/*.tgz et Deploy/SHA256SUMS
```

Nécessite `bash`, `tar`, `gzip`, `sha256sum` (Git Bash ou WSL sous Windows). Les archives sont **reproductibles** : mêmes sources, mêmes octets. Elles sont générées depuis les fichiers du dépôt (une seule source de vérité) ; ce qui est propre aux archives est dans `packaging/templates/`. Les fichiers de `Deploy/` ne se modifient pas à la main : modifier la source, reconstruire, recommiter.

## Tests

```bash
sudo packaging/test_packages.sh
```

1. Contrôle des archives : contenu, empreintes, reproductibilité, syntaxe des scripts, JSON, Python, fichiers cités par les scripts.
2. Intégration (root et PostgreSQL Debian requis, sinon `SKIP`) : installation réelle du dépôt de résultats (cluster temporaire `compadepot`, port 5448), des clusters de test (`pga` 5433, `pgb` 5434), du comparateur (dossiers temporaires), de Grafana (commandes simulées), puis comparaison `PGA/poc_pg` contre `PGB/poc_pg` : **55 écarts** attendus, comparaison planifiée, rejeu de chaque installation.

## Ce que cette version change dans le dépôt

| Changement | Pourquoi |
|---|---|
| `infra/pg_clusters.sh` : lecture des scripts SQL par redirection (`<`) | l'utilisateur `postgres` ne peut pas lire un fichier situé sous `/home/<utilisateur>` : le chargement des bases de test échouait depuis une archive extraite dans le dossier personnel |
| `infra/pg_clusters.sh` : mot de passe via `COMPA_APP_PASSWORD` | installation sans question (la saisie reste le comportement par défaut) |

Le chemin « cloner le dépôt » (README, « Mise en place ») fonctionne comme avant.
