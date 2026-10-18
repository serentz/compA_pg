#!/usr/bin/env bash
# compA_pg : controles apres installation du comparateur.   sudo ./verify.sh
source "$(dirname "${BASH_SOURCE[0]}")/scripts/lib.sh"
need_root
ETC_DIR="${COMPA_ETC_DIR:-/etc/compa_pg}"
BIN_DIR="${COMPA_BIN_DIR:-/usr/local/bin}"
[ -f "$ETC_DIR/compa_pg.env" ] || die "$ETC_DIR/compa_pg.env absent : lancer ./install.sh d'abord."
. "$ETC_DIR/compa_pg.env"
FAIL=0
check() { local label="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$label"; else warn "ECHEC : $label"; FAIL=1; fi; }

check "psql present" command -v psql
check "python3 present" command -v python3
check "compa_pg.sh executable" test -x "$INSTALL_DIR/bash/compa_pg.sh"
check "12 requetes d'extraction" bash -c "[ \$(ls '$INSTALL_DIR'/bash/queries/*.sql | wc -l) -eq 12 ]"
check "compare.py compile" python3 -m py_compile "$INSTALL_DIR/python/compare.py"
check "commande compa_pg installee" test -x "$BIN_DIR/compa_pg"
check "compa_pg.env en 0600" bash -c "[ \"\$(stat -c %a '$ETC_DIR/compa_pg.env')\" = 600 ]"
check "base de resultats joignable, schema compa_pg present" env PGPASSWORD="$PG_PASSWORD" psql -X -At -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" -c "SELECT version FROM compa_pg.schema_version"
n="$(PGPASSWORD="$PG_PASSWORD" psql -X -At -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" -c "SELECT count(*) FROM compa_pg.config_compa_pg WHERE actif" 2>/dev/null || echo '?')"
printf '   clusters declares dans la base de resultats : %s\n' "$n"
[ "$FAIL" -eq 0 ] && ok "Tous les controles sont bons" || die "Au moins un controle a echoue (voir ci-dessus)"
