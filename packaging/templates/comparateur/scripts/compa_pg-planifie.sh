#!/usr/bin/env bash
# compA_pg : lance les comparaisons listees dans /etc/compa_pg/planifie.conf (une par ligne :
# « INSTANCE1 BASE1 INSTANCE2 BASE2 », lignes vides et commentaires # ignores).
# Appele par le timer systemd compa_pg-planifie ou par cron ; code retour 1 si une comparaison echoue.
CONF="${COMPA_PLANIFIE_CONF:-/etc/compa_pg/planifie.conf}"
[ -r "$CONF" ] || { echo "[-] $CONF illisible" >&2; exit 10; }
rc=0 n=0
while read -r i1 d1 i2 d2 extra; do
    case "$i1" in ''|'#'*) continue ;; esac
    [ -n "$d2" ] && [ -z "$extra" ] || { echo "[-] ligne invalide dans $CONF : $i1 $d1 $i2 $d2 $extra" >&2; rc=1; continue; }
    n=$((n + 1))
    echo "[+] comparaison $i1/$d1 contre $i2/$d2"
    compa_pg -S "$i1" -D "$d1" -s "$i2" -d "$d2" || { echo "[-] echec : $i1/$d1 contre $i2/$d2 (code $?)" >&2; rc=1; }
done < "$CONF"
[ "$n" -gt 0 ] || echo "[!] aucune comparaison dans $CONF" >&2
exit $rc
