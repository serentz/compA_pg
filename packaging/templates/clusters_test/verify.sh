#!/usr/bin/env bash
# compA_pg : controles des 2 clusters de test.   sudo ./verify.sh
set -u
source "$(dirname "${BASH_SOURCE[0]}")/scripts/lib.sh"
need_root
FAIL=0
check() { local label="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$label"; else warn "ECHEC : $label"; FAIL=1; fi; }
q() { runuser -u postgres -- psql -X -At -p "$1" -d "${3:-postgres}" -c "$2"; }
for p in 5433 5434; do
    check "cluster du port $p en ligne" q "$p" "SELECT 1"
    check "port $p : base poc_pg presente" bash -c "[ \"\$(runuser -u postgres -- psql -X -At -p $p -d postgres -c \"SELECT count(*) FROM pg_database WHERE datname='poc_pg'\")\" = 1 ]"
    check "port $p : login compa_app superutilisateur" bash -c "[ \"\$(runuser -u postgres -- psql -X -At -p $p -d postgres -c \"SELECT rolsuper::text FROM pg_roles WHERE rolname='compa_app'\")\" = true ]"
done
a="$(q 5433 "SHOW work_mem" 2>/dev/null)"; b="$(q 5434 "SHOW work_mem" 2>/dev/null)"
[ "$a" != "$b" ] && ok "ecart voulu present : work_mem $a (pga) contre $b (pgb)" || { warn "ECHEC : work_mem identique ($a) sur les 2 clusters"; FAIL=1; }
[ "$FAIL" -eq 0 ] && ok "Tous les controles sont bons" || die "Au moins un controle a echoue (voir ci-dessus)"
