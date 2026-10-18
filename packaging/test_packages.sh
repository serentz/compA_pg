#!/usr/bin/env bash
# ============================================================
# compA_pg : tests des archives de deploiement.
#
#   sudo packaging/test_packages.sh
#
# 1. Construit les 4 archives dans un dossier temporaire et controle : contenu, SHA256SUMS, reproductibilite,
#    syntaxe des scripts, JSON, Python, fichiers cites par les scripts presents dans l'archive.
# 2. Test d'integration (root + pg_createcluster requis, sinon SKIP) : installe pour de bon, dans cet ordre,
#    l'archive depot (cluster temporaire), clusters_test (pga 5433, pgb 5434), comparateur (dossiers temporaires),
#    grafana (commandes simulees), puis lance une comparaison PGA/poc_pg contre PGB/poc_pg : 55 ecarts attendus.
# Les etapes sans prerequis sont signalees SKIP. Code de sortie : 0 si aucun echec.
# Attention : cree/demarre les clusters Debian pga (5433), pgb (5434) et compadepot (PORT_DEPOT).
# ============================================================
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
PASS=0 FAIL=0 SKIP=0
PORT_DEPOT="${PORT_DEPOT:-5448}"
DEPOT_CLUSTER=compadepot
PGV=""

ok()   { PASS=$((PASS+1)); echo "  ok   - $1"; }
ko()   { FAIL=$((FAIL+1)); echo "  FAIL - $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | head -n 10 | sed 's/^/         | /'; }
skip() { SKIP=$((SKIP+1)); echo "  SKIP - $1"; }
check() { local label="$1" out; shift; if out="$("$@" 2>&1)"; then ok "$label"; else ko "$label" "$out"; fi; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else ko "$1 (attendu '$3', obtenu '$2')"; fi; }

cleanup() {
    if [ -n "$PGV" ]; then
        pg_dropcluster --stop "$PGV" "$DEPOT_CLUSTER" >/dev/null 2>&1 || true
        pg_ctlcluster "$PGV" pga stop >/dev/null 2>&1 || true
        pg_ctlcluster "$PGV" pgb stop >/dev/null 2>&1 || true
    fi
    rm -rf "$T"
}
trap cleanup EXIT

PKGS=(depot comparateur grafana clusters_test)

echo "== Construction =="
check "build_packages.sh" env OUT_DIR="$T/dist" "$ROOT/packaging/build_packages.sh" vTEST
check "build reproductible (2e build identique)" bash -c "OUT_DIR='$T/dist2' '$ROOT/packaging/build_packages.sh' vTEST >/dev/null && diff '$T/dist/SHA256SUMS' '$T/dist2/SHA256SUMS'"
check "SHA256SUMS du dossier de sortie valide" bash -c "cd '$T/dist' && sha256sum -c SHA256SUMS --quiet"
mkdir -p "$T/x"
for p in "${PKGS[@]}"; do tar xzf "$T/dist/compa_pg_$p.tgz" -C "$T/x" || ko "extraction de $p"; done

expected() {
    case "$1" in
    depot) echo LISEZMOI.md install.sh verify.sh scripts/lib.sh scripts/compa_pg.env.example scripts/declarer-instance.sh sql/create_schema.sql ;;
    comparateur) echo LISEZMOI.md install.sh verify.sh scripts/lib.sh scripts/compa_pg.env.example scripts/compa_pg-planifie.sh scripts/planifie.conf.example \
        systemd/compa_pg-planifie.service systemd/compa_pg-planifie.timer cron/compa_pg.cron bash/compa_pg.sh python/compare.py \
        bash/queries/inst_config.sql bash/queries/db_size.sql bash/queries/db_options.sql bash/queries/obj_tables.sql bash/queries/obj_indexes.sql \
        bash/queries/obj_code.sql bash/queries/obj_source.sql bash/queries/constraints.sql bash/queries/extensions.sql bash/queries/sequences.sql \
        bash/queries/roles.sql bash/queries/grants.sql ;;
    grafana) echo LISEZMOI.md install.sh verify.sh scripts/lib.sh scripts/compa_pg.env.example provisioning/datasources/compa_pg.yaml \
        provisioning/dashboards/compa_pg.yaml dashboards/compapg-home.json ;;
    clusters_test) echo LISEZMOI.md install.sh verify.sh scripts/lib.sh scripts/compa_pg.env.example infra/pg_clusters.sh \
        sql/pg_test/01_create_poc_db_cluster1.sql sql/pg_test/02_create_poc_db_cluster2.sql ;;
    esac
}

for p in "${PKGS[@]}"; do
    D="$T/x/compa_pg_$p"
    echo "== Archive $p =="
    missing=""
    for f in $(expected "$p") VERSION SHA256SUMS; do [ -f "$D/$f" ] || missing="$missing $f"; done
    [ -z "$missing" ] && ok "contenu attendu present" || ko "fichiers manquants :$missing"
    check "SHA256SUMS valide" bash -c "cd '$D' && sha256sum -c SHA256SUMS --quiet"
    eq "VERSION indique la version" "$(sed -n 1p "$D/VERSION")" "compA_pg vTEST"
    [ -z "$(find "$D" -name 'compa_pg.env' -o -name '*.pgpass')" ] && ok "aucun secret dans l'archive" || ko "secret present dans l'archive"
    grep -rl --exclude='*.json' '{{' "$D" >/dev/null 2>&1 && ko "marqueur {{...}} non remplace" || ok "marqueurs de modele remplaces"
    for s in install.sh verify.sh; do [ -x "$D/$s" ] && ok "$s executable" || ko "$s non executable"; done
    for f in $(cd "$D" && find . -name '*.sh' | sed 's|^\./||'); do check "bash -n $f" bash -n "$D/$f"; done
    for f in $(cd "$D" && find . -name '*.json' | sed 's|^\./||'); do python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$D/$f" 2>/dev/null || ko "JSON invalide : $f"; done
    for f in $(cd "$D" && find . -name '*.py' | sed 's|^\./||'); do check "python compile : $f" python3 -m py_compile "$D/$f"; done
    # Fermeture : chaque nom de fichier cite (hors commentaires) par les scripts d'installation existe dans l'archive.
    allow='^(compa_pg\.env|compa_pg\.conf|postgresql\.conf|pg_hba\.conf|grafana\.list|grafana\.gpg|gpg\.key|sources\.list|pg_clusters\.sh|compa_pg\.sh|planifie\.conf|compa_pg\.cron|declarer-instance\.sh|compa_pg-planifie\.(sh|service|timer)|compa_pg\.yaml|create_schema\.sql|compare\.py|lib\.sh|verify\.sh|install\.sh|grafana-server|planifie\.conf\.example|compa_pg\.env\.example)$'
    refs="$(cd "$D" && cat install.sh scripts/declarer-instance.sh scripts/compa_pg-planifie.sh 2>/dev/null | sed -e 's/^[[:space:]]*#.*//' -e 's/[[:space:]]#.*//' \
        | grep -o '[A-Za-z0-9_][A-Za-z0-9_.-]*\.\(py\|sql\|service\|timer\|json\|sh\|yaml\|cron\|example\)' | sort -u)"
    unresolved=""
    for r in $refs; do
        echo "$r" | grep -Eq "$allow" && { [ -n "$(find "$D" -name "$r" -print -quit)" ] || echo "$r" | grep -Eq '^(compa_pg\.conf|postgresql\.conf|pg_hba\.conf|grafana\.list|grafana\.gpg|gpg\.key|sources\.list|compa_pg\.sh|compa_pg\.env|planifie\.conf|compa_pg-planifie\.(sh|service|timer)|compa_pg\.cron)$' || unresolved="$unresolved $r"; continue; }
        [ -n "$(find "$D" -name "$r" -print -quit)" ] || unresolved="$unresolved $r"
    done
    [ -z "$unresolved" ] && ok "tout fichier cite par les scripts est dans l'archive" || ko "cites mais absents de l'archive :$unresolved"
done
eq "13 dashboards dans l'archive grafana" "$(ls "$T/x/compa_pg_grafana/dashboards/"*.json | wc -l)" "13"
for f in "$ROOT"/grafana/dashboards/*.json; do cmp -s "$f" "$T/x/compa_pg_grafana/dashboards/$(basename "$f")" || ko "dashboard modifie : $f"; done
eq "12 requetes dans l'archive comparateur" "$(ls "$T/x/compa_pg_comparateur/bash/queries/"*.sql | wc -l)" "12"
cmp -s "$ROOT/sql/postgres/create_schema.sql" "$T/x/compa_pg_depot/sql/create_schema.sql" && ok "schema identique a celui du depot Git" || ko "schema different"

echo "== Integration : installation reelle des 4 archives =="
PGV="$(ls /usr/lib/postgresql 2>/dev/null | sort -n | tail -n 1)"
if [ "$(id -u)" -ne 0 ] || [ -z "$PGV" ] || ! command -v pg_createcluster >/dev/null || ! command -v psql >/dev/null; then
    skip "root, PostgreSQL Debian (pg_createcluster) et psql requis"; PGV=""
else
    SECRET_APP="Test_compa_app_1"; SECRET_RO="Test_grafana_1"
    pg_dropcluster --stop "$PGV" "$DEPOT_CLUSTER" >/dev/null 2>&1 || true
    pg_createcluster "$PGV" "$DEPOT_CLUSTER" --port "$PORT_DEPOT" >/dev/null 2>&1
    pg_ctlcluster "$PGV" "$DEPOT_CLUSTER" start

    # --- depot ---
    D="$T/x/compa_pg_depot"
    cat > "$D/scripts/compa_pg.env" <<ENV
PG_PORT=$PORT_DEPOT
DEPOT_DB=compa
DEPOT_OWNER=compa_app
DEPOT_OWNER_PASSWORD=$SECRET_APP
GRAFANA_RO_PASSWORD=$SECRET_RO
ALLOW_SUBNET=127.0.0.1/32
ENV
    check "depot : install.sh" "$D/install.sh"
    check "depot : install.sh rejoue (idempotent)" "$D/install.sh"
    check "depot : verify.sh" "$D/verify.sh"

    # --- clusters de test ---
    C="$T/x/compa_pg_clusters_test"
    printf 'COMPA_APP_PASSWORD=%s\nCOMPA_NET=127.0.0.0/8\n' "$SECRET_APP" > "$C/scripts/compa_pg.env"
    check "clusters_test : install.sh" "$C/install.sh" "$PGV"
    check "clusters_test : verify.sh" "$C/verify.sh"

    # --- declaration des clusters a comparer ---
    export INSTANCE_PASSWORD="$SECRET_APP"
    check "depot : declarer-instance.sh PGA" "$D/scripts/declarer-instance.sh" PGA 127.0.0.1 5433 compa_app "cluster de test 1"
    check "depot : declarer-instance.sh PGB" "$D/scripts/declarer-instance.sh" PGB 127.0.0.1 5434 compa_app
    check "depot : declarer-instance.sh PGB (mise a jour)" "$D/scripts/declarer-instance.sh" PGB 127.0.0.1 5434 compa_app "cluster de test 2"
    unset INSTANCE_PASSWORD
    eq "2 clusters declares" "$(runuser -u postgres -- psql -X -At -p "$PORT_DEPOT" -d compa -c 'SELECT count(*) FROM compa_pg.config_compa_pg')" "2"

    # --- comparateur ---
    M="$T/x/compa_pg_comparateur"; mkdir -p "$T/inst" "$T/etc" "$T/bin"
    cat > "$M/scripts/compa_pg.env" <<ENV
PG_HOST=127.0.0.1
PG_PORT=$PORT_DEPOT
PG_DB=compa
PG_USER=compa_app
PG_PASSWORD=$SECRET_APP
INSTALL_DIR=$T/inst
RUN_USER=root
ENV
    export COMPA_ETC_DIR="$T/etc" COMPA_BIN_DIR="$T/bin" COMPA_UNIT_DIR="$T/units"
    check "comparateur : install.sh" "$M/install.sh"
    check "comparateur : install.sh rejoue" "$M/install.sh"
    check "comparateur : verify.sh" "$M/verify.sh"
    eq "compa_pg.env en 0600" "$(stat -c %a "$T/etc/compa_pg.env")" "600"
    out="$(PATH="$T/bin:$PATH" "$T/bin/compa_pg" -S PGA -D poc_pg -s PGB -d poc_pg 2>&1)"; rc=$?
    eq "compa_pg PGA/poc_pg contre PGB/poc_pg : code retour 0" "$rc" "0"
    [ "$rc" -eq 0 ] || printf '%s\n' "$out" | tail -n 8 | sed 's/^/         | /'
    P="runuser -u postgres -- psql -X -At -p $PORT_DEPOT -d compa"
    total="$($P -c "SELECT sum(nb) FROM (SELECT count(*) nb FROM compa_pg.diff_inst_config UNION ALL SELECT count(*) FROM compa_pg.diff_db_size UNION ALL SELECT count(*) FROM compa_pg.diff_db_options UNION ALL SELECT count(*) FROM compa_pg.diff_obj_tables UNION ALL SELECT count(*) FROM compa_pg.diff_obj_indexes UNION ALL SELECT count(*) FROM compa_pg.diff_obj_code UNION ALL SELECT count(*) FROM compa_pg.diff_obj_source UNION ALL SELECT count(*) FROM compa_pg.diff_constraints UNION ALL SELECT count(*) FROM compa_pg.diff_extensions UNION ALL SELECT count(*) FROM compa_pg.diff_sequences UNION ALL SELECT count(*) FROM compa_pg.diff_roles UNION ALL SELECT count(*) FROM compa_pg.diff_grants) x")"
    eq "55 ecarts enregistres (clusters de test)" "$total" "55"
    # Planification : planifie.conf + compa_pg-planifie
    echo "PGA poc_pg PGB poc_pg" > "$T/etc/planifie.conf"
    out="$(PATH="$T/bin:$PATH" COMPA_PLANIFIE_CONF="$T/etc/planifie.conf" "$T/bin/compa_pg-planifie" 2>&1)"; rc=$?
    eq "compa_pg-planifie : code retour 0" "$rc" "0"
    eq "2 runs enregistres apres la comparaison planifiee" "$($P -c 'SELECT count(*) FROM compa_pg.run')" "2"
    echo "PGA poc_pg PGINCONNU poc_pg" > "$T/etc/planifie.conf"
    PATH="$T/bin:$PATH" COMPA_PLANIFIE_CONF="$T/etc/planifie.conf" "$T/bin/compa_pg-planifie" >/dev/null 2>&1; rc=$?
    eq "compa_pg-planifie : instance inconnue -> code retour 1" "$rc" "1"
    unset COMPA_ETC_DIR COMPA_BIN_DIR COMPA_UNIT_DIR

    # --- grafana (commandes simulees, dossiers temporaires) ---
    G="$T/x/compa_pg_grafana"; mkdir -p "$T/stubs"
    printf '#!/bin/sh\nexit 0\n' > "$T/stubs/grafana-server"; chmod +x "$T/stubs/grafana-server"
    cat > "$G/scripts/compa_pg.env" <<ENV
COMPA_PG_HOST=127.0.0.1
COMPA_PG_PORT=$PORT_DEPOT
COMPA_PG_DB=compa
COMPA_PG_PASSWORD=$SECRET_RO
ENV
    export GRAFANA_DEFAULTS_FILE="$T/default-grafana-server" GRAFANA_PROV_DIR="$T/prov" GRAFANA_DASH_DIR="$T/dash/compa_pg"
    printf '# reglages par defaut de Grafana\nGRAFANA_USER=grafana\n' > "$GRAFANA_DEFAULTS_FILE"
    check "grafana : install.sh" env PATH="$T/stubs:$PATH" "$G/install.sh"
    check "grafana : install.sh rejoue" env PATH="$T/stubs:$PATH" "$G/install.sh"
    eq "grafana : reglages par defaut conserves" "$(grep -c '^GRAFANA_USER=grafana' "$GRAFANA_DEFAULTS_FILE")" "1"
    eq "grafana : un seul bloc COMPA_PG env apres rejeu" "$(grep -c '^# BEGIN COMPA_PG env' "$GRAFANA_DEFAULTS_FILE")" "1"
    eq "grafana : 13 dashboards copies" "$(ls "$GRAFANA_DASH_DIR"/*.json | wc -l)" "13"
    check "grafana : verify.sh" env PATH="$T/stubs:$PATH" "$G/verify.sh"
    check "grafana_ro lit les resultats mais pas config_compa_pg" bash -c "PGPASSWORD='$SECRET_RO' psql -X -At -h 127.0.0.1 -p $PORT_DEPOT -U grafana_ro -d compa -c 'SELECT count(*) FROM compa_pg.run' && ! PGPASSWORD='$SECRET_RO' psql -X -At -h 127.0.0.1 -p $PORT_DEPOT -U grafana_ro -d compa -c 'SELECT 1 FROM compa_pg.config_compa_pg' 2>/dev/null"
    unset GRAFANA_DEFAULTS_FILE GRAFANA_PROV_DIR GRAFANA_DASH_DIR
fi

echo
echo "Resultat : $PASS ok, $FAIL echec(s), $SKIP ignore(s)"
[ "$FAIL" -eq 0 ]
