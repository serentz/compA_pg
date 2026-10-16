#!/bin/bash
# ==============================================================================
# compa_pg.sh - Comparaison de deux couples instance/base PostgreSQL
#
# 1. verifie la base de resultats (schema compa_pg), lit les acces aux clusters dans config_compa_pg
# 2. cree/retrouve la reference (refid) et ouvre un run (run_id)
# 3. extrait 12 modules x 2 cotes vers des CSV (requetes dans bash/queries/*.sql, via psql --csv)
# 4. appelle python/compare.py qui compare et enregistre les ecarts dans la base de resultats
#
# Format des CSV : docs/format_csv.md
# ==============================================================================
set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
QUERIES_DIR="${COMPA_QUERIES_DIR:-$SCRIPT_DIR/queries}"
COMPARE_PY="${COMPA_COMPARE_PY:-$PROJECT_DIR/python/compare.py}"
WORK_ROOT="${COMPA_WORKDIR:-${TMPDIR:-/tmp}}"
if [ -n "${COMPA_PYTHON:-}" ]; then
    PY="$COMPA_PYTHON"
elif [ -x "$PROJECT_DIR/.venv/bin/python" ]; then
    PY="$PROJECT_DIR/.venv/bin/python"
else
    PY="python3"
fi

# Codes retour (en plus de ceux de compare.py : 2 = CSV invalide, 3 = erreur PostgreSQL)
E_USAGE=1       # arguments invalides
E_PREREQ=10     # outil manquant ou PostgreSQL injoignable
E_SCHEMA=11     # schema ou tables PostgreSQL absents
E_CONFIG=12     # instance absente de config_compa_pg
E_SRC=13        # connexion ou extraction sur un cluster compare en echec

MODULES=(inst_config db_size db_options obj_tables obj_indexes obj_code obj_source constraints extensions sequences roles grants)
declare -A HEADERS=(
    [inst_config]="name|value|unit|source"
    [db_size]="item|size_mb"
    [db_options]="option|value"
    [obj_tables]="table_name|column_name|type_name|not_null|default_value|identity|generated"
    [obj_indexes]="table_name|index_name|is_unique|is_primary|definition"
    [obj_code]="object_name|object_type"
    [obj_source]="object_name|object_type|colid|text_hex"
    [constraints]="table_name|constraint_name|constraint_type|definition"
    [extensions]="extension|version|schema"
    [sequences]="sequence_name|data_type|start_value|increment_by|min_value|max_value|cycle|cache_size"
    [roles]="role_name|can_login|superuser|create_db|create_role|inherit|replication|bypass_rls|conn_limit|member_of"
    [grants]="object_type|object_name|grantee|privileges"
)
REQUIRED_TABLES="'schema_version','ref_execution','run','config_compa_pg','exclusion_rules','diff_inst_config','diff_db_size','diff_db_options','diff_obj_tables','diff_obj_indexes','diff_obj_code','diff_obj_source','diff_constraints','diff_extensions','diff_sequences','diff_roles','diff_grants'"
REQUIRED_TABLES_COUNT=17

log() { echo "[+] $*"; }
warn() { echo "[!] $*" >&2; }
err() { echo "[-] $*" >&2; }

usage() {
    cat >&2 <<EOF
Usage: $0 -S <instance1> -D <base1> -s <instance2> -d <base2> -U <login_pg> [options]

  -S  cluster 1 (config_compa_pg)   -D  base de donnees 1
  -s  cluster 2 (config_compa_pg)   -d  base de donnees 2
  -U  login base de resultats    -P  mot de passe base de resultats (preferer PGPASSWORD ou ~/.pgpass)
  -H  hote base de resultats     -p  port                      -n  nom de la base de resultats
  -k  conserver les CSV du run (par defaut : supprimes en fin d'execution)
  -h  cette aide

Les acces aux clusters compares (hote, port, login, mot de passe) sont lus dans compa_pg.config_compa_pg.
EOF
    exit $E_USAGE
}

# ------------------------------------------------------------------------------
# Arguments
# ------------------------------------------------------------------------------
SRV1="" DB1="" SRV2="" DB2=""
PG_USER="" PG_PASS="" PG_HOST="" PG_PORT="" PG_DB=""
KEEP=0

while getopts "S:D:s:d:U:P:H:p:n:kh" opt; do
    case $opt in
        S) SRV1=$OPTARG ;;
        D) DB1=$OPTARG ;;
        s) SRV2=$OPTARG ;;
        d) DB2=$OPTARG ;;
        U) PG_USER=$OPTARG ;;
        P) PG_PASS=$OPTARG ;;
        H) PG_HOST=$OPTARG ;;
        p) PG_PORT=$OPTARG ;;
        n) PG_DB=$OPTARG ;;
        k) KEEP=1 ;;
        *) usage ;;
    esac
done

if [ -z "$SRV1" ] || [ -z "$DB1" ] || [ -z "$SRV2" ] || [ -z "$DB2" ] || [ -z "$PG_USER" ]; then
    err "Les parametres -S, -D, -s, -d et -U sont obligatoires."
    usage
fi

# Les noms sont reinjectes dans des requetes et des chemins : liste blanche de caracteres
for v in "$SRV1" "$DB1" "$SRV2" "$DB2"; do
    if ! [[ $v =~ ^[A-Za-z0-9_.-]+$ ]]; then
        err "Valeur invalide '$v' : seuls les lettres, chiffres, '_', '.' et '-' sont acceptes."
        exit $E_USAGE
    fi
done
if [ -n "$PG_PORT" ] && ! [[ $PG_PORT =~ ^[0-9]+$ ]]; then
    err "Le port PostgreSQL doit etre numerique."
    exit $E_USAGE
fi
[ -n "$PG_PASS" ] && warn "-P est visible dans la liste des processus : preferer PGPASSWORD ou ~/.pgpass."

# ------------------------------------------------------------------------------
# Acces PostgreSQL
# ------------------------------------------------------------------------------
PG_ARGS=(-X -v ON_ERROR_STOP=1 -U "$PG_USER")
[ -n "$PG_HOST" ] && PG_ARGS+=(-h "$PG_HOST")
[ -n "$PG_PORT" ] && PG_ARGS+=(-p "$PG_PORT")
[ -n "$PG_DB" ] && PG_ARGS+=(-d "$PG_DB")
[ -n "$PG_PASS" ] && export PGPASSWORD="$PG_PASS"

pg() { psql "${PG_ARGS[@]}" "$@"; }

# ------------------------------------------------------------------------------
# Nettoyage et suivi du run
# ------------------------------------------------------------------------------
WORK=""
RUN_ID=""
REFID=""
RUN_OPEN=0

fail_run() {
    # Marque le run en ERREUR (au mieux : ne masque pas l'erreur d'origine)
    [ -n "$RUN_ID" ] || return 0
    pg -q -At -o /dev/null -v rid="$RUN_ID" -v msg="$1" >/dev/null 2>&1 <<'SQL'
select compa_pg.end_run(:rid, 'ERREUR', :'msg');
SQL
    RUN_OPEN=0
}

cleanup() {
    local rc=$?
    if [ "$RUN_OPEN" = 1 ]; then
        fail_run "script interrompu (code $rc)"
    fi
    if [ -n "$WORK" ] && [ -d "$WORK" ]; then
        if [ "$KEEP" = 1 ]; then
            log "CSV conserves dans $WORK"
        else
            rm -rf "$WORK"
        fi
    fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# ------------------------------------------------------------------------------
# Pre-controles
# ------------------------------------------------------------------------------
for cmd in psql "$PY"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        err "Commande introuvable : $cmd"
        exit $E_PREREQ
    fi
done
if [ ! -f "$COMPARE_PY" ]; then
    err "compare.py introuvable : $COMPARE_PY"
    exit $E_PREREQ
fi
for mod in "${MODULES[@]}"; do
    if [ ! -f "$QUERIES_DIR/$mod.sql" ]; then
        err "Requete manquante : $QUERIES_DIR/$mod.sql"
        exit $E_PREREQ
    fi
done

nb_tables=$(pg -At -c "select count(*) from information_schema.tables where table_schema = 'compa_pg' and table_name in ($REQUIRED_TABLES)" 2>&1)
if [ $? -ne 0 ]; then
    err "Connexion PostgreSQL impossible : $nb_tables"
    exit $E_PREREQ
fi
if [ "$nb_tables" != "$REQUIRED_TABLES_COUNT" ]; then
    err "Le schema compa_pg est absent ou incomplet ($nb_tables/$REQUIRED_TABLES_COUNT tables)."
    err "Executer d'abord le script de creation : psql -f sql/postgres/create_schema.sql"
    exit $E_SCHEMA
fi
log "PostgreSQL : schema compa_pg present."

# ------------------------------------------------------------------------------
# Acces aux clusters compares (table config_compa_pg)
# ------------------------------------------------------------------------------
declare -A SRC_HOST SRC_PORT SRC_LOGIN SRC_PASS

fetch_creds() {   # $1 = 1|2 (cote), $2 = instance
    local row
    row=$(pg -At -F $'\t' -v inst="$2" 2>&1 <<'SQL'
select host, port, login, password from compa_pg.config_compa_pg where instance = :'inst' and actif;
SQL
    )
    if [ $? -ne 0 ]; then
        err "Lecture de config_compa_pg impossible : $row"
        exit $E_PREREQ
    fi
    if [ -z "$row" ]; then
        err "Instance '$2' absente (ou inactive) de compa_pg.config_compa_pg : l'y declarer avant de relancer."
        exit $E_CONFIG
    fi
    IFS=$'\t' read -r "SRC_HOST[$1]" "SRC_PORT[$1]" "SRC_LOGIN[$1]" "SRC_PASS[$1]" <<<"$row"
}

fetch_creds 1 "$SRV1"
fetch_creds 2 "$SRV2"

# ------------------------------------------------------------------------------
# Acces aux clusters compares via psql
#   Le mot de passe est transmis par PGPASSWORD dans l'environnement du seul processus psql,
#   jamais en argument : il n'apparait donc pas dans la liste des processus.
#   search_path = pg_catalog impose, sinon pg_get_expr / pg_get_constraintdef ne qualifient les noms
#   de schema que selon le search_path de la base (faux ecarts entre deux bases configurees differemment).
# ------------------------------------------------------------------------------
PSQL_ERR=""

run_src() {   # $1 = cote (1|2), $2 = base, $3 = fichier de requete, $4 = fichier de sortie (CSV, avec en-tete)
    local rc
    PSQL_ERR=$(PGPASSWORD="${SRC_PASS[$1]}" PGCONNECT_TIMEOUT=10 PGCLIENTENCODING=UTF8 PGOPTIONS='-c search_path=pg_catalog' \
        psql -X -w -v ON_ERROR_STOP=1 -h "${SRC_HOST[$1]}" -p "${SRC_PORT[$1]}" -U "${SRC_LOGIN[$1]}" -d "$2" \
             --csv -P null=NULL -P csv_fieldsep='|' -f "$3" -o "$4" 2>&1 >/dev/null)
    rc=$?
    return $rc
}

show_src_error() {
    printf '%s\n' "$PSQL_ERR" | grep -v '^[[:space:]]*$' | head -n 3 | sed 's/^/    /' >&2
}

check_src() {   # $1 = cote, $2 = instance, $3 = base
    log "Connexion a $2 (${SRC_HOST[$1]}:${SRC_PORT[$1]}), base $3..."
    if ! run_src "$1" "$3" <(echo "select 1") /dev/null; then
        err "Connexion au cluster '$2' / base '$3' impossible :"
        show_src_error
        exit $E_SRC
    fi
}

extract_side() {   # $1 = cote (1|2), $2 = instance, $3 = base
    local mod out="$WORK/r$1" header
    for mod in "${MODULES[@]}"; do
        log "Extraction $2.$3 : $mod"
        if ! run_src "$1" "$3" "$QUERIES_DIR/$mod.sql" "${out}_${mod}.csv"; then
            err "Echec de l'extraction du module $mod sur $2.$3 :"
            show_src_error
            return 1
        fi
        header=$(head -n 1 "${out}_${mod}.csv" | tr -d '\r')
        if [ "$header" != "${HEADERS[$mod]}" ]; then
            err "En-tete inattendu pour $mod ($header) : requete $mod.sql modifiee ?"
            return 1
        fi
    done
}

check_src 1 "$SRV1" "$DB1"
check_src 2 "$SRV2" "$DB2"

# ------------------------------------------------------------------------------
# Reference (refid) et run
# ------------------------------------------------------------------------------
REFID=$(pg -At -v i1="$SRV1" -v b1="$DB1" -v i2="$SRV2" -v b2="$DB2" 2>&1 <<'SQL'
select compa_pg.get_or_create_refid(:'i1', :'b1', :'i2', :'b2');
SQL
)
if ! [[ $REFID =~ ^[0-9]+$ ]]; then
    err "Creation de la reference impossible : $REFID"
    exit $E_PREREQ
fi
RUN_ID=$(pg -At -v refid="$REFID" 2>&1 <<'SQL'
select compa_pg.start_run(:refid);
SQL
)
if ! [[ $RUN_ID =~ ^[0-9]+$ ]]; then
    err "Ouverture du run impossible : $RUN_ID"
    RUN_ID=""
    exit $E_PREREQ
fi
RUN_OPEN=1
log "Reference refid=$REFID : $SRV1.$DB1 vs $SRV2.$DB2 (run_id=$RUN_ID)"

# ------------------------------------------------------------------------------
# Extraction (12 modules x 2 cotes)
# ------------------------------------------------------------------------------
WORK=$(mktemp -d "$WORK_ROOT/compa_pg_run${RUN_ID}_XXXXXX") || { fail_run "dossier de travail impossible"; exit $E_PREREQ; }
chmod 700 "$WORK"

if ! extract_side 1 "$SRV1" "$DB1" || ! extract_side 2 "$SRV2" "$DB2"; then
    fail_run "echec de l'extraction"
    exit $E_SRC
fi

# ------------------------------------------------------------------------------
# Comparaison (compare.py enregistre les ecarts et cloture le run)
# ------------------------------------------------------------------------------
COMPARE_ARGS=(--csv-dir "$WORK" --run-id "$RUN_ID" --refid "$REFID" -U "$PG_USER")
[ -n "$PG_HOST" ] && COMPARE_ARGS+=(-H "$PG_HOST")
[ -n "$PG_PORT" ] && COMPARE_ARGS+=(-p "$PG_PORT")
[ -n "$PG_DB" ] && COMPARE_ARGS+=(-n "$PG_DB")

log "Comparaison des extractions..."
"$PY" "$COMPARE_PY" "${COMPARE_ARGS[@]}"
rc=$?
RUN_OPEN=0      # compare.py a cloture le run (TERMINE ou ERREUR)
exit $rc
