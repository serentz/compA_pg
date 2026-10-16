#!/bin/bash
# ==============================================================================
# pg_clusters.sh - Cree les deux clusters PostgreSQL de test sur pg01 (Ubuntu/Debian)
#
#   cluster "pga"  port 5433  : cluster 1 (reference)
#   cluster "pgb"  port 5434  : cluster 2 (compare), work_mem different (ecart voulu)
#
# Usage (sur pg01, en tant qu'administrateur) :
#   sudo bash infra/pg_clusters.sh [version_pg]        # defaut : version installee (ex. 16)
#
# Le script :
#   - cree les clusters avec pg_createcluster (idempotent : un cluster existant est conserve) ;
#   - ouvre l'ecoute reseau (listen_addresses = '*') et l'acces md5/scram depuis le reseau du POC ;
#   - cree un role superutilisateur de test `compa_app` (mot de passe demande, jamais versionne) ;
#   - execute sql/pg_test/01_*.sql sur pga et 02_*.sql sur pgb (bases poc_pg avec ecarts voulus).
#
# POC uniquement : ne pas reproduire cette ouverture reseau ni ce superutilisateur ailleurs.
# ==============================================================================
set -euo pipefail

VER="${1:-$(ls /usr/lib/postgresql | sort -n | tail -n 1)}"
NET="${COMPA_NET:-192.168.50.0/24}"
HERE="$(cd "$(dirname "$0")" && pwd)"
TESTSQL="$HERE/../sql/pg_test"

[ "$(id -u)" -eq 0 ] || { echo "[-] A lancer avec sudo." >&2; exit 1; }
[ -d "/usr/lib/postgresql/$VER" ] || { echo "[-] PostgreSQL $VER absent (apt install postgresql-$VER)." >&2; exit 1; }

read -r -s -p "Mot de passe du role compa_app (>= 8 caracteres) : " PW; echo
[ "${#PW}" -ge 8 ] || { echo "[-] Mot de passe trop court." >&2; exit 1; }

make_cluster() {   # $1 nom, $2 port
    if pg_lsclusters -h | awk '{print $1" "$2}' | grep -q "^$VER $1$"; then
        echo "[+] Cluster $VER/$1 deja present."
    else
        echo "[+] Creation du cluster $VER/$1 (port $2)..."
        pg_createcluster "$VER" "$1" --port="$2"
    fi
    local conf="/etc/postgresql/$VER/$1"
    sed -i "s/^#\?listen_addresses.*/listen_addresses = '*'/" "$conf/postgresql.conf"
    grep -q "compa_pg test" "$conf/pg_hba.conf" || \
        echo "host all all $NET scram-sha-256   # compa_pg test" >> "$conf/pg_hba.conf"
    pg_ctlcluster "$VER" "$1" restart
}

sql_as_postgres() {   # $1 port, reste : arguments psql
    local port=$1; shift
    sudo -u postgres psql -X -p "$port" -v ON_ERROR_STOP=1 -d postgres "$@"
}

make_cluster pga 5433
make_cluster pgb 5434

for port in 5433 5434; do
    sql_as_postgres "$port" -q -v pw="$PW" <<'SQL'
select format('create role compa_app login superuser password %L', :'pw')
 where not exists (select 1 from pg_roles where rolname = 'compa_app') \gexec
select format('alter role compa_app password %L', :'pw')
 where exists (select 1 from pg_roles where rolname = 'compa_app') \gexec
SQL
done

echo "[+] Chargement des bases de test..."
sql_as_postgres 5433 -q -f "$TESTSQL/01_create_poc_db_cluster1.sql"
sql_as_postgres 5434 -q -f "$TESTSQL/02_create_poc_db_cluster2.sql"
pg_lsclusters
echo "[+] Termine. Declarer ensuite les deux clusters dans compa_pg.config_compa_pg (voir README)."
