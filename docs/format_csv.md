# Format des CSV d'extraction (contrat bash → Python)

Ce document définit ce que `bash/compa_pg.sh` produit (via `psql --csv`) et ce que `compare.py` lit.
Les requêtes de `bash/queries/` peuvent être adaptées tant que **les fichiers et colonnes ci-dessous sont respectés** :
le script vérifie l'en-tête de chaque fichier avant de lancer la comparaison.

## 1. Appel de `compare.py`

```
python compare.py --csv-dir <dossier> --run-id <run_id> --refid <refid> \
                  -H <hote_pg> -p <port_pg> -n <base_pg> -U <login_pg> [-P <mot_de_passe_pg>]
```

- `run_id` et `refid` sont créés **avant** l'extraction par le bash :
  `SELECT compa_pg.get_or_create_refid(:instance1, :base1, :instance2, :base2);` puis `SELECT compa_pg.start_run(:refid);`
- À la fin, `compare.py` appelle `compa_pg.end_run(run_id, 'TERMINE')`, ou `'ERREUR'` avec un message en cas d'échec.
- Mot de passe : `PGPASSWORD` ou `.pgpass` (recommandé : un argument `-P` est visible dans `ps`).
- Options : `--dry-run` (compare et affiche sans accéder à la base de résultats), `-v` (liste chaque écart).
- Les écarts d'une exécution sont insérés en **une seule transaction** avec la clôture du run : en cas d'erreur, rien n'est écrit et le run passe en `ERREUR`.
- Aucune dépendance pip : bibliothèque standard et client `psql`.

| Code retour | Signification |
|---|---|
| 0 | Comparaison terminée (avec ou sans écart) |
| 2 | CSV manquant, vide ou invalide |
| 3 | Erreur PostgreSQL |

## 2. Fichiers attendus

Un dossier de travail par exécution, contenant **24 fichiers** : un par module et par côté.
`r1_` = cluster 1 / base 1, `r2_` = cluster 2 / base 2.

```
r1_<module>.csv   r2_<module>.csv    pour <module> dans :
inst_config db_size db_options obj_tables obj_indexes obj_code obj_source constraints extensions sequences roles grants
```

## 3. Règles générales

| Règle | Détail |
|---|---|
| Encodage | UTF-8 (`PGCLIENTENCODING=UTF8` imposé par le script) |
| Séparateur | `\|` (pipe). Un champ contenant `\|`, un guillemet ou un retour à la ligne est écrit entre guillemets `"..."`, guillemets doublés : format `psql --csv`, lu avec le module `csv` de Python |
| En-tête | Première ligne obligatoire = noms de colonnes de la requête, exactement comme ci-dessous |
| Espaces | **Significatifs** : aucune suppression (contrairement à l'extraction ASE, `psql --csv` ne remplit pas) |
| NULL | Écrit `NULL` (`-P null=NULL`) ; une chaîne vide reste vide. `compare.py` convertit `NULL` en valeur nulle |
| Lignes vides | Ignorées |
| Fichier sans donnée | Autorisé (en-tête seul) : « aucune ligne ». Un fichier **absent ou vide, sans en-tête** est une erreur d'extraction (code 2) |
| Ordre des lignes | Sans importance, `compare.py` joint par clé |
| Doublons de clé | Erreur (code 2) |
| Nombre de colonnes | Une ligne dont le nombre de colonnes diffère de l'en-tête est une erreur (code 2) |

Limite : une valeur texte égale à `NULL` est lue comme NULL.

## 4. Contenu par module

| Module | Colonnes (dans l'ordre) | Clé | Champs comparés |
|---|---|---|---|
| `inst_config` | `name`, `value`, `unit`, `source` | `name` | `value` (`unit`, `source` sont affichés) |
| `db_size` | `item`, `size_mb` | `item` (`database`, `schema:<nom>`) | `size_mb` |
| `db_options` | `option`, `value` | `option` (`owner`, `encoding`, `collate`, `ctype`, `connection_limit`, `allow_connections`, `is_template`, `tablespace`, `setting:<nom>`) | `value` |
| `obj_tables` | `table_name`, `column_name`, `type_name`, `not_null`, `default_value`, `identity`, `generated` | `table_name` (`schéma.table`) + `column_name` | tous les autres |
| `obj_indexes` | `table_name`, `index_name`, `is_unique`, `is_primary`, `definition` | `table_name` + `index_name` | tous les autres |
| `obj_code` | `object_name`, `object_type` | `object_name` + `object_type` | présence |
| `obj_source` | `object_name`, `object_type`, `colid`, `text_hex` | `object_name` + `object_type` | empreinte MD5 du texte |
| `constraints` | `table_name`, `constraint_name`, `constraint_type`, `definition` | `table_name` + `constraint_name` | `constraint_type`, `definition` |
| `extensions` | `extension`, `version`, `schema` | `extension` | `version`, `schema` |
| `sequences` | `sequence_name`, `data_type`, `start_value`, `increment_by`, `min_value`, `max_value`, `cycle`, `cache_size` | `sequence_name` | tous les autres |
| `roles` | `role_name`, `can_login`, `superuser`, `create_db`, `create_role`, `inherit`, `replication`, `bypass_rls`, `conn_limit`, `member_of` | `role_name` | tous les autres |
| `grants` | `object_type`, `object_name`, `grantee`, `privileges` | les 3 premières | `privileges` |

Précisions :

- Types d'objet de `obj_code` / `obj_source` : `V` vue, `M` vue matérialisée, `F` fonction, `P` procédure, `TR` trigger. Les fonctions sont identifiées par leurs arguments (`schéma.nom(arguments)`), les triggers par `schéma.table.trigger`. Les fonctions fournies par une extension sont exclues.
- `obj_source` : un bloc par objet (`colid` = 1), texte UTF-8 en hexadécimal (`pg_get_viewdef`, `pg_get_functiondef`, `pg_get_triggerdef`). `compare.py` normalise (fins de ligne, espaces de fin de ligne) puis calcule le MD5 ; les textes ne sont stockés que pour les objets en écart. Plusieurs blocs par objet restent acceptés (ordre `colid`).
- `grants` : `object_type` vaut `database`, `schema`, `table` (tables, vues, vues matérialisées), `sequence` ou `function` ; `grantee` vaut `PUBLIC` pour tous ; `privileges` est la liste triée séparée par des virgules.
- Les schémas système (`pg_catalog`, `information_schema`, `pg_*`) sont exclus des extractions.

## 5. Règles d'exclusion

La table `compa_pg.exclusion_rules` retire ou marque des écarts connus :

| Colonne | Rôle |
|---|---|
| `module` | Un des 12 modules |
| `cle_pattern` | Motif `LIKE` appliqué à la clé de la ligne, composants séparés par un point (`app.orders.comment`, `table.app.orders.app_ro`). `%` = toutes |
| `colonne` | Champ concerné, `*` = toute la ligne |
| `action` | `IGNORE` : écart non enregistré. `ATTENDU` : enregistré avec `attendu = true` |

Exemple : tous les paramètres `shared_%` sont dimensionnés par serveur :

```sql
INSERT INTO compa_pg.exclusion_rules (module, cle_pattern, colonne, action, motif)
VALUES ('inst_config', 'shared_%', 'value', 'ATTENDU', 'dimensionné par serveur');
```

Une règle `ATTENDU` sur une colonne ne marque l'écart attendu que si **toutes** les colonnes en écart sont couvertes. Aucune règle par défaut n'est livrée.
