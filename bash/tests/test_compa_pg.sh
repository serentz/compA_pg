#!/bin/bash
# ==============================================================================
# Tests d'integration de bash/compa_pg.sh.
#
# Prerequis :
#   - une base de resultats ou sql/postgres/create_schema.sql a ete execute ;
#   - deux clusters PostgreSQL de test ou ont ete executes sql/pg_test/01_*.sql (cluster 1)
#     et 02_*.sql (cluster 2) -- voir infra/pg_clusters.sh.
#
#   export COMPA_TEST_DB=compa PGHOST=<hote> PGPORT=5432 PGUSER=<login> PGPASSWORD=<mdp>
#   export COMPA_TEST_SRC1=<hote>:<port> COMPA_TEST_SRC2=<hote>:<port>
#   export COMPA_TEST_SRC_USER=<login> COMPA_TEST_SRC_PASS=<mdp>      # superutilisateur de test
#   bash/tests/test_compa_pg.sh
# ==============================================================================
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../compa_pg.sh"

: "${COMPA_TEST_DB:?definir COMPA_TEST_DB (base de resultats avec le schema compa_pg)}"
: "${PGUSER:?definir PGUSER}"
: "${COMPA_TEST_SRC1:?definir COMPA_TEST_SRC1 (hote:port du cluster 1)}"
: "${COMPA_TEST_SRC2:?definir COMPA_TEST_SRC2 (hote:port du cluster 2)}"
: "${COMPA_TEST_SRC_USER:?definir COMPA_TEST_SRC_USER}"
: "${COMPA_TEST_SRC_PASS:?definir COMPA_TEST_SRC_PASS}"

H1=${COMPA_TEST_SRC1%:*} P1=${COMPA_TEST_SRC1##*:}
H2=${COMPA_TEST_SRC2%:*} P2=${COMPA_TEST_SRC2##*:}
PASS=0 FAIL=0
LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT

P() { psql -X -At -v ON_ERROR_STOP=1 -d "$COMPA_TEST_DB" "$@"; }
ok()   { PASS=$((PASS + 1)); echo "  ok   - $1"; }
ko()   { FAIL=$((FAIL + 1)); echo "  FAIL - $1"; [ -s "$LOG" ] && sed 's/^/         | /' "$LOG" | head -n 12; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else ko "$1 (attendu '$3', obtenu '$2')"; fi; }

cmd() { "$SCRIPT" -S T_PGA -D poc_pg -s T_PGB -d poc_pg -U "$PGUSER" -n "$COMPA_TEST_DB" \
        ${PGHOST:+-H "$PGHOST"} ${PGPORT:+-p "$PGPORT"} "$@"; }

echo "== Preparation : acces aux clusters de test =="
P -q -v h1="$H1" -v p1="$P1" -v h2="$H2" -v p2="$P2" -v u="$COMPA_TEST_SRC_USER" -v w="$COMPA_TEST_SRC_PASS" <<'SQL'
insert into compa_pg.config_compa_pg (instance, host, port, login, password)
values ('T_PGA', :'h1', :'p1', :'u', :'w'), ('T_PGB', :'h2', :'p2', :'u', :'w')
on conflict (instance) do update set host = excluded.host, port = excluded.port, login = excluded.login,
                                     password = excluded.password, actif = true;
SQL

echo "== 1. Execution nominale =="
cmd >"$LOG" 2>&1; rc=$?
check "code retour 0" "$rc" "0"
n=$(sed -n 's/^\[✓\] \([0-9]*\) ecart(s) enregistre(s).*/\1/p' "$LOG")
[ -n "$n" ] && [ "$n" -ge 54 ] && [ "$n" -le 56 ] && ok "$n ecarts enregistres (55 attendus, +-1 : taille des schemas)" || ko "ecarts enregistres ($n)"
refid1=$(P -c "select max(refid) from compa_pg.ref_execution where instance1='T_PGA' and instance2='T_PGB'")
run1=$(P -c "select max(run_id) from compa_pg.run where refid=$refid1")
check "run termine" "$(P -c "select statut from compa_pg.run where run_id=$run1")" "TERMINE"
check "lignes dans les tables diff = ecarts" "$(P -c "select coalesce(sum(nb),0) from compa_pg.v_synthese_run where run_id=$run1")" "$n"
check "12 modules presents dans la synthese" "$(P -c "select count(distinct module) from compa_pg.v_synthese_run where run_id=$run1")" "12"
check "nettoyage : aucun dossier de travail restant" "$(ls -d "${TMPDIR:-/tmp}"/compa_pg_run${run1}_* 2>/dev/null | wc -l)" "0"

echo "== 2. Meme couple : refid reutilise, nouveau run =="
cmd >"$LOG" 2>&1; rc=$?
check "code retour 0" "$rc" "0"
check "refid inchange" "$(P -c "select count(*) from compa_pg.ref_execution where instance1='T_PGA' and base1='poc_pg' and instance2='T_PGB' and base2='poc_pg'")" "1"
run2=$(P -c "select max(run_id) from compa_pg.run where refid=$refid1")
[ "$run2" -gt "$run1" ] && ok "nouveau run_id ($run1 -> $run2)" || ko "nouveau run_id"

echo "== 3. Option -k : CSV conserves et formats conformes =="
cmd -k >"$LOG" 2>&1; rc=$?
check "code retour 0" "$rc" "0"
dir=$(sed -n 's/^\[+\] CSV conserves dans //p' "$LOG")
if [ -d "$dir" ]; then
    check "24 fichiers CSV" "$(ls "$dir" | wc -l)" "24"
    check "en-tete extensions" "$(head -n1 "$dir/r1_extensions.csv")" "extension|version|schema"
    check "extension citext cote 1 seulement" "$(grep -c '^citext|' "$dir/r1_extensions.csv"):$(grep -c '^citext|' "$dir/r2_extensions.csv")" "1:0"
    check "mot de passe absent des CSV" "$(grep -l "$COMPA_TEST_SRC_PASS" "$dir"/*.csv | wc -l)" "0"
    check "permissions du dossier 700" "$(stat -c %a "$dir")" "700"
    rm -rf "$dir"
else
    ko "dossier CSV conserve introuvable"
fi

echo "== 4. Erreurs =="
"$SCRIPT" -D poc_pg -s T_PGB -d poc_pg -U u >"$LOG" 2>&1; check "argument manquant -> 1" "$?" "1"
"$SCRIPT" -S "a;b" -D x -s y -d z -U u >"$LOG" 2>&1; check "nom invalide -> 1" "$?" "1"

"$SCRIPT" -S T_INCONNU -D poc_pg -s T_PGB -d poc_pg -U "$PGUSER" -n "$COMPA_TEST_DB" \
    ${PGHOST:+-H "$PGHOST"} ${PGPORT:+-p "$PGPORT"} >"$LOG" 2>&1; rc=$?
check "instance absente de config_compa_pg -> 12" "$rc" "12"
grep -q "config_compa_pg" "$LOG" && ok "message explicite" || ko "message explicite"

runs_before=$(P -c "select count(*) from compa_pg.run")
"$SCRIPT" -S T_PGA -D base_inexistante -s T_PGB -d poc_pg -U "$PGUSER" -n "$COMPA_TEST_DB" \
    ${PGHOST:+-H "$PGHOST"} ${PGPORT:+-p "$PGPORT"} >"$LOG" 2>&1; rc=$?
check "base inexistante -> 13" "$rc" "13"
check "aucun run cree avant la verification des acces" "$(P -c "select count(*) from compa_pg.run")" "$runs_before"

P -q -c "update compa_pg.config_compa_pg set password='mauvais' where instance='T_PGA'"
cmd >"$LOG" 2>&1; check "mauvais mot de passe -> 13" "$?" "13"
P -q -v w="$COMPA_TEST_SRC_PASS" <<'SQL'
update compa_pg.config_compa_pg set password = :'w' where instance = 'T_PGA';
SQL

echo "== 5. Schema absent =="
empty="compa_empty_$$"
if createdb "$empty" 2>/dev/null; then
    "$SCRIPT" -S T_PGA -D poc_pg -s T_PGB -d poc_pg -U "$PGUSER" -n "$empty" \
        ${PGHOST:+-H "$PGHOST"} ${PGPORT:+-p "$PGPORT"} >"$LOG" 2>&1; rc=$?
    check "schema absent -> 11" "$rc" "11"
    grep -q "create_schema.sql" "$LOG" && ok "message : executer create_schema.sql" || ko "message : executer create_schema.sql"
    dropdb "$empty"
else
    echo "  skip - createdb impossible"
fi

echo "== Nettoyage =="
P -q -c "delete from compa_pg.config_compa_pg where instance in ('T_PGA','T_PGB')"

echo
echo "Resultat : $PASS ok, $FAIL en echec"
[ "$FAIL" -eq 0 ]
