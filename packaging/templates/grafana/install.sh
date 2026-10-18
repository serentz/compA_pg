#!/usr/bin/env bash
# ============================================================
# compA_pg : installation de Grafana, de la source de donnees et des 13 dashboards
#
#   sudo ./install.sh
#
# Installe Grafana (depot apt grafana.com) s'il manque, ecrit les variables COMPA_PG_* dans
# /etc/default/grafana-server, copie la provision (source de donnees + dashboards) et redemarre Grafana.
# Rejouable. Prerequis : base de resultats installee (archive « depot »), scripts/compa_pg.env renseigne.
# ============================================================
source "$(dirname "${BASH_SOURCE[0]}")/scripts/lib.sh"
need_root
load_env
require_vars COMPA_PG_HOST COMPA_PG_PORT COMPA_PG_DB COMPA_PG_PASSWORD
check_password COMPA_PG_PASSWORD
[[ "$COMPA_PG_PORT" =~ ^[0-9]+$ ]] || die "COMPA_PG_PORT invalide."
[[ "$COMPA_PG_DB" =~ ^[A-Za-z0-9_]+$ ]] || die "COMPA_PG_DB invalide."
[[ "$COMPA_PG_HOST" =~ ^[A-Za-z0-9_.-]+$ ]] || die "COMPA_PG_HOST invalide."

# Emplacements (surchargeables pour les tests)
DEFAULTS_FILE="${GRAFANA_DEFAULTS_FILE:-/etc/default/grafana-server}"
PROV_DIR="${GRAFANA_PROV_DIR:-/etc/grafana/provisioning}"
DASH_DIR="${GRAFANA_DASH_DIR:-/var/lib/grafana/dashboards/compa_pg}"

# --- 1. Grafana ----------------------------------------------------------------------------
if ! command -v grafana-server >/dev/null 2>&1; then
    log "Installation de Grafana"
    apt_install apt-transport-https software-properties-common wget gnupg curl
    mkdir -p /etc/apt/keyrings
    wget -q -O - https://apt.grafana.com/gpg.key | gpg --dearmor -o /etc/apt/keyrings/grafana.gpg --yes
    echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" > /etc/apt/sources.list.d/grafana.list
    _APT_UPDATED=""
    apt_install grafana
fi
ok "Grafana present"

# --- 2. Variables de la source de donnees ------------------------------------------------------
# Ajoutees (sans remplacer le fichier : il contient les reglages par defaut de Grafana) dans un bloc gere.
CHANGED=0
set_block "$DEFAULTS_FILE" env \
    "COMPA_PG_HOST=$COMPA_PG_HOST" \
    "COMPA_PG_PORT=$COMPA_PG_PORT" \
    "COMPA_PG_DB=$COMPA_PG_DB" \
    "COMPA_PG_PASSWORD=$COMPA_PG_PASSWORD"
chmod 0640 "$DEFAULTS_FILE"
getent group grafana >/dev/null 2>&1 && chgrp grafana "$DEFAULTS_FILE" 2>/dev/null || true

# --- 3. Provision et dashboards -----------------------------------------------------------------
install_file "$REPO_DIR/provisioning/datasources/compa_pg.yaml" "$PROV_DIR/datasources/compa_pg.yaml" 0644
install_file "$REPO_DIR/provisioning/dashboards/compa_pg.yaml" "$PROV_DIR/dashboards/compa_pg.yaml" 0644
mkdir -p "$DASH_DIR"
for f in "$REPO_DIR"/dashboards/*.json; do install_file "$f" "$DASH_DIR/$(basename "$f")" 0644; done
if id grafana >/dev/null 2>&1; then chown -R grafana:grafana "$(dirname "$DASH_DIR")"; fi
ok "$(ls "$DASH_DIR"/*.json | wc -l) dashboards dans $DASH_DIR"

# --- 4. Demarrage ------------------------------------------------------------------------------
if [ -d /run/systemd/system ]; then
    systemctl enable grafana-server >/dev/null 2>&1 || true
    if [ "$CHANGED" -eq 1 ]; then systemctl restart grafana-server; else systemctl start grafana-server; fi
    ok "Grafana demarre (port 3000)"
fi
log "Termine. Ouvrir http://<ip>:3000 (admin / admin la premiere fois), dossier « Comparaison PostgreSQL ». Verification : sudo ./verify.sh"
