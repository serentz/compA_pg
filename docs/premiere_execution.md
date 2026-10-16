# Première exécution sur un nouvel environnement

Liste de contrôle à suivre avant de lancer `bash/compa_pg.sh` sur des clusters autres que ceux du POC.
Le script ne fait que des lectures sur les clusters comparés (requêtes `select` sur les catalogues) ;
seul le schéma `compa_pg` de la base de résultats reçoit des données.

## 1. Poste d'exécution

- [ ] `psql` et Python 3.8+ installés ; la version de `psql` est celle du plus récent des clusters (ou plus).
- [ ] Les clusters comparés sont joignables depuis le poste (`psql -h <hote> -p <port> -U <login> -d <base>`), y compris `pg_hba.conf` et le pare-feu.
- [ ] Les fichiers viennent d'un dépôt Git ou d'un `scp` sans fins de ligne Windows (`dos2unix` sinon).

## 2. Droits du login sur les clusters comparés

Un login **sans droit particulier** suffit : les catalogues (`pg_catalog`) sont lisibles par tout rôle. Limites :

- Un login non superutilisateur ne voit pas la valeur de certains paramètres réservés de `pg_settings` (elle sort en `NULL`) :
  `GRANT pg_read_all_settings TO <login>` (ou `pg_monitor`) pour les voir.

## 3. Premier run : toujours avec `-k`

```
bash bash/compa_pg.sh -S <inst1> -D <base1> -s <inst2> -d <base2> -U <login_pg> -H <hote_pg> -p 5432 -n <base_pg> -k
```

`-k` conserve les CSV dans `/tmp/compa_pg_run<N>_*`. Contrôle-les avant d'interpréter les écarts :

```
D=$(ls -d /tmp/compa_pg_run*/ | tail -1)
wc -l $D/*.csv                       # volumétrie par module
head -3 $D/r1_inst_config.csv        # en-têtes et valeurs
```

Le script s'arrête avec un message si un en-tête ne correspond pas au contrat (`docs/format_csv.md`).

## 4. Volumétrie et durée

- `obj_source` extrait le code de toutes les vues, fonctions et triggers (hexadécimal) : le CSV peut être gros sur une base riche en code. Teste d'abord sur une base modeste.
- `obj_tables`, `obj_indexes`, `constraints` et `grants` parcourent tout le catalogue de la base.
- `db_size` appelle `pg_total_relation_size` sur chaque relation : coûteux sur des milliers de tables.

## 5. Interpréter les premiers écarts

Un premier run remonte toujours du bruit. Lis la liste avant de conclure, puis écarte ce qui est sans intérêt avec
`compa_pg.exclusion_rules` (`docs/format_csv.md`, section 5). Sources courantes de bruit :

- `inst_config` : paramètres dimensionnés par serveur (`shared_buffers`, `max_connections`, `effective_cache_size`...), `server_version` différente.
- `db_size` : tailles différentes pour des données identiques (bloat, `VACUUM`).
- `obj_source` : fonctions qui contiennent un nom de schéma ou d'hôte propre à l'environnement.
- `roles` / `grants` : rôles techniques de l'hébergeur (sauvegarde, supervision), propriétaires différents.
- `extensions` : une extension en version différente entre deux versions majeures de PostgreSQL.

## 6. Particularités PostgreSQL à connaître

- Les extractions imposent `search_path = pg_catalog` : tous les noms sont qualifiés. Ne pas retirer ce réglage.
- Deux versions majeures différentes comparées : `pg_get_viewdef` / `pg_get_functiondef` peuvent reformater le même code, d'où des écarts `obj_source` sans différence réelle.
- Les valeurs de `pg_settings` sont lues telles que le serveur les expose (unité de base : `work_mem` en Ko).
- Les fonctions fournies par une extension (`pg_trgm`...) ne sont pas listées ; l'extension l'est (module `extensions`).

## 7. Sécurité

- [ ] Login dédié, en lecture seule (pas `postgres`), mot de passe saisi hors historique shell.
- [ ] Les CSV conservés avec `-k` contiennent le **code source** et la liste des rôles : supprime-les après contrôle (`rm -r /tmp/compa_pg_run*`).
- [ ] `compa_pg.config_compa_pg` contient des mots de passe : jamais lisible par Grafana (déjà le cas pour `grafana_ro`), jamais versionnée.
- [ ] Mot de passe de la base de résultats par `PGPASSWORD` ou `~/.pgpass`, jamais en option `-P`.

## 8. Grafana

Les dashboards sont générés par `grafana/build_dashboards.py` et supposent la source de données de
`grafana/provisioning/datasources/compa_pg.yaml` (uid `compa_pg_ds`). Si ton Grafana a déjà ses propres
conventions (dossiers, source de données, variables), adapte le générateur et régénère les JSON plutôt que de
modifier les fichiers à la main.
