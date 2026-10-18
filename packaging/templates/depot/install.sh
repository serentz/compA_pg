#!/usr/bin/env bash
# ============================================================
# compA_pg : installation de la base de resultats (schema compa_pg)
#
#   sudo ./install.sh
#
# Installe PostgreSQL s'il manque, ouvre l'ecoute reseau, cree le login proprietaire et la base,
# applique sql/create_schema.sql et active le role Grafana lecture seule. Rejouable.
# Prerequis : Ubuntu/Debian, acces apt, scripts/compa_pg.env renseigne.
# ============================================================
source "$(dirname "${BASH_SOURCE[0]}")/scripts/lib.sh"
need_root
load_env
require_vars PG_PORT DEPOT_DB DEPOT_OWNER DEPOT_OWNER_PASSWORD GRAFANA_RO_PASSWORD ALLOW_SUBNET
check_password DEPOT_OWNER_PASSWORD
check_password GRAFANA_RO_PASSWORD
[[ "$DEPOT_DB" =~ ^[A-Za-z0-9_]+$ ]] || die "DEPOT_DB invalide : lettres, chiffres et _ uniquement."
[[ "$DEPOT_OWNER" =~ ^[A-Za-z0-9_]+$ ]] || die "DEPOT_OWNER invalide : lettres, chiffres et _ uniquement."
[[ "$PG_PORT" =~ ^[0-9]+$ ]] || die "PG_PORT invalide."

# Commande psql (surchargeable pour les tests : PSQL_CMD="... psql -p 5448")
PSQL_CMD="${PSQL_CMD:-runuser -u postgres -- psql -X -q -v ON_ERROR_STOP=1 -p $PG_PORT}"

# --- 1. PostgreSQL ------------------------------------------------------------------------
if ! command -v pg_lsclusters >/dev/null 2>&1; then
    log "Installation de PostgreSQL"
    apt_install postgresql
fi
read -r PGVER PGNAME < <(pg_lsclusters -h | awk -v p="$PG_PORT" '$3==p {print $1, $2; exit}')
[ -n "${PGVER:-}" ] || die "Aucun cluster PostgreSQL n'ecoute sur le port $PG_PORT (pg_lsclusters)."
CONF_DIR="/etc/postgresql/$PGVER/$PGNAME"
SERVICE="postgresql@$PGVER-$PGNAME"
ok "cluster $PGVER/$PGNAME (port $PG_PORT)"

# --- 2. Reseau : ecoute et acces -----------------------------------------------------------
mkdir -p "$CONF_DIR/conf.d"
grep -Eq "^\s*include_dir\s*=\s*'conf\.d'" "$CONF_DIR/postgresql.conf" || echo "include_dir = 'conf.d'" >> "$CONF_DIR/postgresql.conf"
CHANGED=0
tmp="$(mktemp)"
printf "# Gere par compA_pg (archive depot) : ne pas modifier a la main.\nlisten_addresses = '*'\n" > "$tmp"
install_file "$tmp" "$CONF_DIR/conf.d/compa_pg.conf" 0644; rm -f "$tmp"
listen_changed=$CHANGED
CHANGED=0
set_block "$CONF_DIR/pg_hba.conf" depot \
    "host    $DEPOT_DB    $DEPOT_OWNER    $ALLOW_SUBNET    scram-sha-256" \
    "host    $DEPOT_DB    grafana_ro      $ALLOW_SUBNET    scram-sha-256"
pg_action() { # restart|reload : systemd si present, sinon pg_ctlcluster
    if [ -d /run/systemd/system ]; then systemctl "$1" "$SERVICE"; else pg_ctlcluster "$PGVER" "$PGNAME" "$1"; fi
}
if [ "$listen_changed" -eq 1 ]; then
    log "Redemarrage de PostgreSQL (coupure de quelques secondes)"
    pg_action restart
elif [ "$CHANGED" -eq 1 ]; then
    log "Rechargement de la configuration"
    pg_action reload
fi
for _ in $(seq 1 30); do $PSQL_CMD -d postgres -c 'SELECT 1' >/dev/null 2>&1 && break; sleep 1; done
$PSQL_CMD -d postgres -c 'SELECT 1' >/dev/null 2>&1 || die "PostgreSQL ne repond pas : journalctl -xeu $SERVICE"

# --- 3. Login proprietaire et base --------------------------------------------------------
log "Login $DEPOT_OWNER et base $DEPOT_DB"
$PSQL_CMD -d postgres -v pw="$DEPOT_OWNER_PASSWORD" -v own="$DEPOT_OWNER" <<'SQL'
select format('create role %I login createrole password %L', :'own', :'pw')
 where not exists (select 1 from pg_roles where rolname = :'own') \gexec
select format('alter role %I login createrole password %L', :'own', :'pw') \gexec
SQL
if [ "$($PSQL_CMD -d postgres -At -c "SELECT 1 FROM pg_database WHERE datname = '$DEPOT_DB'")" != "1" ]; then
    $PSQL_CMD -d postgres -c "CREATE DATABASE $DEPOT_DB OWNER $DEPOT_OWNER"
    log "base $DEPOT_DB creee"
fi

# --- 4. Schema compa_pg ---------------------------------------------------------------------
# Execute sous l'identite du proprietaire (PGOPTIONS role=...) : les objets lui appartiennent.
log "Schema compa_pg (sql/create_schema.sql)"
PGOPTIONS="-c role=$DEPOT_OWNER" $PSQL_CMD -d "$DEPOT_DB" < "$REPO_DIR/sql/create_schema.sql"
$PSQL_CMD -d "$DEPOT_DB" -v pw="$GRAFANA_RO_PASSWORD" <<'SQL'
select format('alter role grafana_ro login password %L', :'pw') \gexec
SQL
n="$($PSQL_CMD -d "$DEPOT_DB" -At -c "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'compa_pg' AND table_type = 'BASE TABLE'")"
ok "schema compa_pg en place ($n tables ; 17 attendues)"

log "Termine. Etape suivante : declarer les clusters a comparer (./scripts/declarer-instance.sh) et verifier : sudo ./verify.sh"
