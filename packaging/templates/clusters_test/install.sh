#!/usr/bin/env bash
# compA_pg : cree les 2 clusters PostgreSQL de TEST (pga 5433, pgb 5434) avec les bases poc_pg et leurs ecarts voulus.
#   sudo ./install.sh [version_pg]
# POC uniquement : ouverture reseau et superutilisateur de test. Voir LISEZMOI.md.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$HERE/scripts/compa_pg.env" ]; then set -a; . "$HERE/scripts/compa_pg.env"; set +a; fi
exec bash "$HERE/infra/pg_clusters.sh" "$@"
