#!/usr/bin/env bash
# ============================================================
# compA_pg : installation du comparateur (extraction psql + compare.py)
#
#   sudo ./install.sh
#
# Installe psql et Python 3, copie les programmes dans INSTALL_DIR, ecrit l'acces a la base de resultats
# dans /etc/compa_pg/compa_pg.env (lisible par RUN_USER seul) et cree la commande `compa_pg`.
# Rejouable. Prerequis : base de resultats installee (archive « depot »), scripts/compa_pg.env renseigne.
# ============================================================
source "$(dirname "${BASH_SOURCE[0]}")/scripts/lib.sh"
need_root
load_env
require_vars PG_HOST PG_PORT PG_DB PG_USER PG_PASSWORD
check_password PG_PASSWORD
INSTALL_DIR="${INSTALL_DIR:-/opt/compa_pg}"
RUN_USER="${RUN_USER:-${SUDO_USER:-}}"
[ -n "$RUN_USER" ] || die "RUN_USER vide et SUDO_USER inconnu : renseigner RUN_USER dans compa_pg.env."
id "$RUN_USER" >/dev/null 2>&1 || die "Le login Linux '$RUN_USER' (RUN_USER) n'existe pas."
ETC_DIR="${COMPA_ETC_DIR:-/etc/compa_pg}"      # surchargeables pour les tests
BIN_DIR="${COMPA_BIN_DIR:-/usr/local/bin}"
UNIT_DIR="${COMPA_UNIT_DIR:-/etc/systemd/system}"

# --- 1. Composants ----------------------------------------------------------------------------
missing=()
command -v psql >/dev/null 2>&1 || missing+=(postgresql-client)
command -v python3 >/dev/null 2>&1 || missing+=(python3)
if [ "${#missing[@]}" -gt 0 ]; then log "Installation de : ${missing[*]}"; apt_install "${missing[@]}"; fi
ok "psql $(psql --version | awk '{print $3}'), $(python3 --version)"

# --- 2. Programmes ----------------------------------------------------------------------------
log "Programmes dans $INSTALL_DIR"
mkdir -p "$INSTALL_DIR/bash/queries" "$INSTALL_DIR/python"
install_file "$REPO_DIR/bash/compa_pg.sh" "$INSTALL_DIR/bash/compa_pg.sh" 0755
for f in "$REPO_DIR"/bash/queries/*.sql; do install_file "$f" "$INSTALL_DIR/bash/queries/$(basename "$f")" 0644; done
install_file "$REPO_DIR/python/compare.py" "$INSTALL_DIR/python/compare.py" 0755
install_file "$REPO_DIR/scripts/compa_pg-planifie.sh" "$BIN_DIR/compa_pg-planifie" 0755
ok "$(ls "$INSTALL_DIR"/bash/queries/*.sql | wc -l) requetes d'extraction, compare.py, compa_pg.sh"

# --- 3. Acces a la base de resultats --------------------------------------------------------
mkdir -p "$ETC_DIR"
envtmp="$(mktemp)"
cat > "$envtmp" <<ENVF
# Gere par compA_pg (archive comparateur). Acces a la base de resultats ; lu par la commande compa_pg.
PG_HOST=$PG_HOST
PG_PORT=$PG_PORT
PG_DB=$PG_DB
PG_USER=$PG_USER
PG_PASSWORD=$PG_PASSWORD
INSTALL_DIR=$INSTALL_DIR
ENVF
install_file "$envtmp" "$ETC_DIR/compa_pg.env" 0600; rm -f "$envtmp"
chown "$RUN_USER" "$ETC_DIR/compa_pg.env" 2>/dev/null || true
chmod 0600 "$ETC_DIR/compa_pg.env"
# Liste des comparaisons planifiees : une ligne « INSTANCE1 BASE1 INSTANCE2 BASE2 », conservee si elle existe.
if [ ! -f "$ETC_DIR/planifie.conf" ]; then
    install -m 0644 "$REPO_DIR/scripts/planifie.conf.example" "$ETC_DIR/planifie.conf"
    log "cree : $ETC_DIR/planifie.conf (a editer pour la comparaison planifiee)"
fi

# --- 4. Commande compa_pg ------------------------------------------------------------------
wrap="$(mktemp)"
cat > "$wrap" <<WRAP
#!/usr/bin/env bash
# compA_pg : lance une comparaison avec l'acces a la base de resultats de $ETC_DIR/compa_pg.env.
#   compa_pg -S INSTANCE1 -D BASE1 -s INSTANCE2 -d BASE2 [-k]      (compa_pg -h : aide)
ENV_FILE="\${COMPA_PG_ENV:-$ETC_DIR/compa_pg.env}"
[ -r "\$ENV_FILE" ] || { echo "[-] \$ENV_FILE illisible (reserve a $RUN_USER) : lancer la commande avec ce login." >&2; exit 10; }
set -a; . "\$ENV_FILE"; set +a
export PGPASSWORD="\$PG_PASSWORD"
exec "\$INSTALL_DIR/bash/compa_pg.sh" -U "\$PG_USER" -H "\$PG_HOST" -p "\$PG_PORT" -n "\$PG_DB" "\$@"
WRAP
install_file "$wrap" "$BIN_DIR/compa_pg" 0755; rm -f "$wrap"
ok "commande $BIN_DIR/compa_pg"

# --- 5. Planification (facultative) ---------------------------------------------------------
if [ "${ENABLE_SCHEDULE:-0}" = "1" ] && [ -d /run/systemd/system ]; then
    sed -e "s|^User=.*|User=$RUN_USER|" -e "s|/usr/local/bin|$BIN_DIR|g" "$REPO_DIR/systemd/compa_pg-planifie.service" > "$UNIT_DIR/compa_pg-planifie.service"
    install_file "$REPO_DIR/systemd/compa_pg-planifie.timer" "$UNIT_DIR/compa_pg-planifie.timer" 0644
    systemctl daemon-reload
    systemctl enable --now compa_pg-planifie.timer >/dev/null
    ok "timer compa_pg-planifie actif (tous les jours a 02:30)"
else
    log "Comparaison planifiee non activee (ENABLE_SCHEDULE=0) : voir LISEZMOI.md, section Planification."
fi

# --- 6. Acces a la base de resultats ----------------------------------------------------------
if PGPASSWORD="$PG_PASSWORD" psql -X -At -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" -c "SELECT version FROM compa_pg.schema_version" >/dev/null 2>&1; then
    ok "base de resultats joignable, schema compa_pg present"
else
    warn "Base de resultats injoignable ($PG_USER@$PG_HOST:$PG_PORT/$PG_DB) ou schema compa_pg absent : installer l'archive « depot » d'abord (ALLOW_SUBNET, mot de passe)."
fi
log "Termine. Essai : compa_pg -h   puis   compa_pg -S <inst1> -D <base1> -s <inst2> -d <base2> -k   (login $RUN_USER)"
