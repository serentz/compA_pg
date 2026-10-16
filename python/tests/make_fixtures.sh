#!/bin/bash
# Regenere les CSV de test (fixtures/) a partir de deux clusters PostgreSQL ou ont ete executes
# sql/pg_test/01_create_poc_db_cluster1.sql et 02_create_poc_db_cluster2.sql (+ work_mem 8MB sur le 2).
#
# Usage : PGPASSWORD=... ./make_fixtures.sh <hote1> <port1> <hote2> <port2> <login> [base]
set -eu
H1=${1:?hote1} P1=${2:?port1} H2=${3:?hote2} P2=${4:?port2} U=${5:?login} DB=${6:-poc_pg}
HERE="$(cd "$(dirname "$0")" && pwd)"
Q="$HERE/../../bash/queries"
OUT="$HERE/fixtures"
mkdir -p "$OUT"
for q in "$Q"/*.sql; do
    m=$(basename "$q" .sql)
    for side in 1 2; do
        if [ $side = 1 ]; then h=$H1; p=$P1; else h=$H2; p=$P2; fi
        PGOPTIONS='-c search_path=pg_catalog' psql -X -w -v ON_ERROR_STOP=1 -h "$h" -p "$p" -U "$U" -d "$DB" \
            --csv -P null=NULL -P csv_fieldsep='|' -f "$q" -o "$OUT/r${side}_${m}.csv"
    done
done
echo "Fixtures ecrites dans $OUT"
