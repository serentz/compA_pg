#!/usr/bin/env bash
# compA_pg : controles apres installation de Grafana.   sudo ./verify.sh
source "$(dirname "${BASH_SOURCE[0]}")/scripts/lib.sh"
need_root
load_env
DEFAULTS_FILE="${GRAFANA_DEFAULTS_FILE:-/etc/default/grafana-server}"
DASH_DIR="${GRAFANA_DASH_DIR:-/var/lib/grafana/dashboards/compa_pg}"
PROV_DIR="${GRAFANA_PROV_DIR:-/etc/grafana/provisioning}"
FAIL=0
check() { local label="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$label"; else warn "ECHEC : $label"; FAIL=1; fi; }

check "variables COMPA_PG_* dans $DEFAULTS_FILE" bash -c "grep -q '^COMPA_PG_PASSWORD=' '$DEFAULTS_FILE' && grep -q '^COMPA_PG_HOST=' '$DEFAULTS_FILE'"
check "13 dashboards installes" bash -c "[ \$(ls '$DASH_DIR'/compapg-*.json | wc -l) -eq 13 ]"
check "provision de la source de donnees" test -f "$PROV_DIR/datasources/compa_pg.yaml"
check "provision des dashboards" test -f "$PROV_DIR/dashboards/compa_pg.yaml"
check "base de resultats joignable avec grafana_ro" env PGPASSWORD="$COMPA_PG_PASSWORD" psql -X -At -h "$COMPA_PG_HOST" -p "$COMPA_PG_PORT" -U grafana_ro -d "$COMPA_PG_DB" -c "SELECT count(*) FROM compa_pg.run"
if [ -d /run/systemd/system ]; then
    check "Grafana actif" systemctl is-active --quiet grafana-server
    check "Grafana repond" curl -fs http://localhost:3000/api/health
    if [ -n "${GRAFANA_ADMIN_PASSWORD:-}" ]; then
        check "source de donnees « Comparaison PostgreSQL » : connexion OK" curl -fs -u "admin:$GRAFANA_ADMIN_PASSWORD" http://localhost:3000/api/datasources/uid/compa_pg_ds/health
        n="$(curl -fs -u "admin:$GRAFANA_ADMIN_PASSWORD" 'http://localhost:3000/api/search?type=dash-db&limit=200' 2>/dev/null | python3 -c "import sys,json; print(sum(1 for d in json.load(sys.stdin) if d.get('uid','').startswith('compapg')))" 2>/dev/null || echo 0)"
        [ "$n" -ge 13 ] && ok "13 dashboards visibles dans Grafana" || { warn "ECHEC : $n dashboards visibles dans Grafana (13 attendus ; attendre 30 s apres le demarrage)"; FAIL=1; }
    else
        warn "GRAFANA_ADMIN_PASSWORD vide : source de donnees et dashboards non controles dans Grafana."
    fi
fi
[ "$FAIL" -eq 0 ] && ok "Tous les controles sont bons" || die "Au moins un controle a echoue (voir ci-dessus)"
