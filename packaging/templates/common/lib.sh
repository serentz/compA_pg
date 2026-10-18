#!/usr/bin/env bash
# compA_pg : fonctions communes aux scripts d'installation des archives. A inclure avec `source`.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

log()  { printf '\033[1;34m[compa_pg]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ ok ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[ERREUR]\033[0m %s\n' "$*" >&2; exit 1; }

need_root() { [ "$(id -u)" -eq 0 ] || die "A lancer avec sudo (ou en root)."; }

# load_env : charge scripts/compa_pg.env (ou le fichier donne par COMPA_ENV).
load_env() {
    local f="${COMPA_ENV:-$SCRIPT_DIR/compa_pg.env}"
    [ -f "$f" ] || die "Fichier de parametres absent : $f (copier scripts/compa_pg.env.example en scripts/compa_pg.env et l'adapter)."
    # shellcheck disable=SC1090
    . "$f"
}

require_vars() { local v; for v in "$@"; do [ -n "${!v:-}" ] || die "Parametre $v manquant dans compa_pg.env."; done; }

# check_password NOM : 8 caracteres minimum, sans espace, #, guillemet ni apostrophe (valeurs recopiees dans des fichiers lus par systemd).
check_password() {
    local name="$1" val="${!1:-}"
    [[ "$val" =~ ^[A-Za-z0-9._@%+=-]{8,}$ ]] || die "$name : 8 caracteres minimum, lettres/chiffres/._@%+=- uniquement."
    case "$val" in CHANGEME*) warn "$name porte encore la valeur d'exemple (CHANGEME...) : a remplacer hors POC." ;; esac
}

CHANGED=0
# install_file SOURCE CIBLE [MODE] : copie si le contenu differe ; positionne CHANGED=1 dans ce cas.
install_file() {
    local src="$1" dst="$2" mode="${3:-0644}"
    mkdir -p "$(dirname "$dst")"
    if [ -f "$dst" ] && cmp -s "$src" "$dst"; then return 0; fi
    install -m "$mode" "$src" "$dst"
    CHANGED=1
    log "installe : $dst"
}

_APT_UPDATED=""
apt_install() {
    if [ -z "$_APT_UPDATED" ]; then DEBIAN_FRONTEND=noninteractive apt-get update -qq; _APT_UPDATED=1; fi
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" >/dev/null
}

# set_block FICHIER MARQUEUR LIGNE... : bloc gere (BEGIN/END COMPA_PG <marqueur>) dans un fichier, remplace a chaque execution.
# Positionne CHANGED=1 si le fichier change.
set_block() {
    local file="$1" marker="$2"; shift 2
    local tmp; tmp="$(mktemp)"
    [ -f "$file" ] || : > "$file"
    sed "/^# BEGIN COMPA_PG $marker\$/,/^# END COMPA_PG $marker\$/d" "$file" > "$tmp"
    { cat "$tmp"; echo "# BEGIN COMPA_PG $marker"; printf '%s\n' "$@"; echo "# END COMPA_PG $marker"; } > "$tmp.new"
    if ! cmp -s "$tmp.new" "$file"; then cat "$tmp.new" > "$file"; CHANGED=1; log "$file : bloc '$marker' mis a jour"; fi
    rm -f "$tmp" "$tmp.new"
}
