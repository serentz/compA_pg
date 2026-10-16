#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
compare.py - Comparaison des extractions PostgreSQL et enregistrement des ecarts dans PostgreSQL.

Lit les 24 CSV produits par le script bash (r1_<module>.csv et r2_<module>.csv, format decrit
dans docs/format_csv.md), compare les deux cotes module par module (jointure par cle), applique
les regles d'exclusion de compa_pg.exclusion_rules, puis insere une ligne consolidee par
difference dans les tables compa_pg.diff_<module>.

Aucune dependance pip : seulement la bibliotheque standard et le client `psql`.
Le mot de passe PostgreSQL est transmis a psql par la variable PGPASSWORD (jamais en argument).

Codes retour : 0 = comparaison terminee, 2 = CSV manquant ou invalide, 3 = erreur PostgreSQL.
"""
from __future__ import annotations

import argparse
import csv
import datetime as dt
import hashlib
import io
import os
import re
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from decimal import Decimal, InvalidOperation
from typing import Any, Callable, Dict, List, Optional, Tuple

EXIT_OK = 0
EXIT_CSV = 2
EXIT_PG = 3

SEP = "|"
CSV_NULL = "NULL"        # representation de NULL dans les CSV (psql -P null=NULL)
PG_NULL = "__NULL__"     # marqueur NULL utilise pour \copy
SCHEMA = "compa_pg"


class CsvError(Exception):
    """CSV manquant, vide ou invalide."""


class PgError(Exception):
    """Erreur lors d'un appel a PostgreSQL."""


# ----------------------------------------------------------------------------
# Lecture et conversion des CSV
# ----------------------------------------------------------------------------
def read_csv(path: str, columns: List[str]) -> List[Tuple[int, Dict[str, Optional[str]]]]:
    """Lit un CSV `|` (format `psql --csv`, champs entre guillemets si besoin, en-tete obligatoire).
    Retourne [(numero_de_ligne, {colonne: valeur})]."""
    if not os.path.isfile(path):
        raise CsvError(f"fichier manquant : {path}")
    try:
        with open(path, "r", encoding="utf-8-sig", newline="") as fh:
            text = fh.read()
    except UnicodeDecodeError as exc:
        raise CsvError(f"{path} : encodage invalide, UTF-8 attendu : {exc}")

    reader = csv.reader(io.StringIO(text, newline=""), delimiter=SEP, quotechar='"')
    rows = []
    header: Optional[List[str]] = None
    try:
        for parts in reader:
            lineno = reader.line_num
            if not parts or (len(parts) == 1 and parts[0].strip() == ""):
                continue
            if header is None:
                header = [h.strip() for h in parts]
                if header != columns:
                    raise CsvError(f"{path} : en-tete invalide. Attendu : {SEP.join(columns)} / trouve : {SEP.join(header)}")
                continue
            if len(parts) != len(columns):
                raise CsvError(f"{path} ligne {lineno} : {len(parts)} colonne(s) au lieu de {len(columns)}")
            rows.append((lineno, {c: (None if p == CSV_NULL else p) for c, p in zip(columns, parts)}))
    except csv.Error as exc:
        raise CsvError(f"{path} : CSV invalide : {exc}")
    if header is None:
        raise CsvError(f"{path} : fichier vide, en-tete absent (extraction en erreur ?)")
    return rows


_TS_FORMATS = ("%Y-%m-%d %H:%M:%S", "%Y-%m-%dT%H:%M:%S", "%Y-%m-%d %H:%M:%S.%f", "%Y-%m-%d")


def parse_ts(value: str) -> dt.datetime:
    """Accepte `YYYY-MM-DD HH:MM:SS` (et variantes ISO)."""
    v = re.sub(r"\s+", " ", value.strip())
    for fmt in _TS_FORMATS:
        try:
            return dt.datetime.strptime(v, fmt)
        except ValueError:
            pass
    raise ValueError(value)


def cast(value: Optional[str], kind: str, path: str, lineno: int, col: str) -> Any:
    if value is None:
        return None
    if kind == "text":
        return value
    if value == "":
        return None
    try:
        if kind == "int":
            d = Decimal(value)
            if d != d.to_integral_value():
                raise ValueError(value)
            return int(d)
        if kind == "num":
            return Decimal(value)
        if kind == "ts":
            return parse_ts(value)
    except (ValueError, InvalidOperation):
        raise CsvError(f"{path} ligne {lineno} : valeur invalide pour la colonne {col} ({kind}) : {value!r}")
    raise ValueError(f"type inconnu : {kind}")


# ----------------------------------------------------------------------------
# Definition des modules
# ----------------------------------------------------------------------------
Record = Dict[str, Any]
Prepared = Dict[Tuple[Any, ...], Record]


@dataclass(frozen=True)
class Module:
    name: str
    columns: List[str]                        # colonnes du CSV
    fields: List[Tuple[str, str, str]]        # (colonne CSV, champ, type) pour la lecture generique
    key: List[str]                            # champs formant la cle de jointure
    compare: List[str]                        # champs dont la difference constitue un ecart
    pg_fields: List[str]                       # champs ecrits en r1_<champ> / r2_<champ>
    table: str
    prepare: Optional[Callable[..., Prepared]] = None   # lecture specifique (remplace la lecture generique)
    derive: Optional[Callable[[Record], None]] = None   # champs derives, apres lecture generique


def normalize_source(text: str) -> str:
    """Neutralise fins de ligne, espaces de fin de ligne et lignes vides finales avant le hash."""
    lines = [ln.rstrip() for ln in text.replace("\r\n", "\n").replace("\r", "\n").split("\n")]
    return "\n".join(lines).strip("\n")


def prepare_obj_source(mod: Module, rows, path: str, ctx: Dict[str, Any]) -> Prepared:
    """Reconstitue le code de chaque objet a partir des blocs syscomments (tri sur colid)."""
    encoding = ctx.get("source_encoding", "utf-8")
    chunks: Dict[Tuple[str, str], Dict[int, bytes]] = {}
    for lineno, raw in rows:
        name, otype = raw["object_name"], raw["object_type"]
        if not name or not otype:
            raise CsvError(f"{path} ligne {lineno} : object_name et object_type sont obligatoires")
        colid = cast(raw["colid"], "int", path, lineno, "colid")
        if colid is None:
            raise CsvError(f"{path} ligne {lineno} : colid obligatoire")
        try:
            data = bytes.fromhex(raw["text_hex"] or "")
        except ValueError:
            raise CsvError(f"{path} ligne {lineno} : text_hex n'est pas de l'hexadecimal valide")
        parts = chunks.setdefault((name, otype), {})
        if colid in parts:
            raise CsvError(f"{path} ligne {lineno} : bloc en double ({name}, {otype}, colid={colid})")
        parts[colid] = data

    out: Prepared = {}
    for key, parts in chunks.items():
        raw_bytes = b"".join(parts[c] for c in sorted(parts))
        try:
            text = raw_bytes.decode(encoding)
        except UnicodeDecodeError:
            raise CsvError(f"{path} : code de {key[0]} non decodable en {encoding} (option --source-encoding)")
        norm = normalize_source(text)
        out[key] = {
            "object_name": key[0],
            "object_type": key[1],
            "hash": hashlib.md5(norm.encode("utf-8")).hexdigest(),
            "nb_lignes": len(norm.split("\n")) if norm else 0,
            "source": norm,
        }
    return out


def text_module(name: str, columns: List[str], key: List[str], table: Optional[str] = None,
                compare: Optional[List[str]] = None) -> Module:
    """Module dont toutes les colonnes sont du texte : cle = colonnes `key`, le reste est compare."""
    values = [c for c in columns if c not in key]
    return Module(name, columns, [(c, c, "text") for c in columns], key,
                  compare or values, values, table or f"diff_{name}")


def derive_obj_code(rec: Record) -> None:
    rec["present"] = True


MODULES: List[Module] = [
    text_module("inst_config", ["name", "value", "unit", "source"], ["name"], compare=["value"]),
    Module("db_size", ["item", "size_mb"], [("item", "item", "text"), ("size_mb", "size_mb", "num")],
           ["item"], ["size_mb"], ["size_mb"], "diff_db_size"),
    text_module("db_options", ["option", "value"], ["option"]),
    text_module("obj_tables", ["table_name", "column_name", "type_name", "not_null", "default_value",
                               "identity", "generated"], ["table_name", "column_name"]),
    text_module("obj_indexes", ["table_name", "index_name", "is_unique", "is_primary", "definition"],
                ["table_name", "index_name"]),
    Module("obj_code", ["object_name", "object_type"],
           [("object_name", "object_name", "text"), ("object_type", "object_type", "text")],
           ["object_name", "object_type"], [], ["present"], "diff_obj_code", derive=derive_obj_code),
    Module("obj_source", ["object_name", "object_type", "colid", "text_hex"], [],
           ["object_name", "object_type"], ["hash"], ["hash", "nb_lignes", "source"], "diff_obj_source",
           prepare=prepare_obj_source),
    text_module("constraints", ["table_name", "constraint_name", "constraint_type", "definition"],
                ["table_name", "constraint_name"]),
    text_module("extensions", ["extension", "version", "schema"], ["extension"]),
    text_module("sequences", ["sequence_name", "data_type", "start_value", "increment_by", "min_value",
                              "max_value", "cycle", "cache_size"], ["sequence_name"]),
    text_module("roles", ["role_name", "can_login", "superuser", "create_db", "create_role", "inherit",
                          "replication", "bypass_rls", "conn_limit", "member_of"], ["role_name"]),
    text_module("grants", ["object_type", "object_name", "grantee", "privileges"],
                ["object_type", "object_name", "grantee"]),
]


def build_records(mod: Module, rows, path: str, ctx: Dict[str, Any]) -> Prepared:
    """Transforme les lignes d'un CSV en dictionnaire {cle: enregistrement}."""
    if mod.prepare:
        return mod.prepare(mod, rows, path, ctx)
    out: Prepared = {}
    for lineno, raw in rows:
        rec = {fld: cast(raw[col], kind, path, lineno, col) for col, fld, kind in mod.fields}
        for col, fld, kind in mod.fields:
            if fld in mod.key and rec[fld] is None:
                raise CsvError(f"{path} ligne {lineno} : la colonne cle {col} ne peut pas etre NULL")
        if mod.derive:
            mod.derive(rec)
        key = tuple(rec[k] for k in mod.key)
        if key in out:
            raise CsvError(f"{path} ligne {lineno} : cle en double {'.'.join(str(k) for k in key) or '(ligne unique)'}")
        out[key] = rec
    return out


# ----------------------------------------------------------------------------
# Regles d'exclusion
# ----------------------------------------------------------------------------
def like_to_regex(pattern: str) -> "re.Pattern[str]":
    out = []
    for ch in pattern:
        out.append(".*" if ch == "%" else "." if ch == "_" else re.escape(ch))
    return re.compile("^" + "".join(out) + "$", re.S)


@dataclass(frozen=True)
class Rule:
    module: str
    pattern: str
    colonne: str     # '*' = toute la ligne, sinon nom d'un champ compare
    action: str      # IGNORE ou ATTENDU
    regex: Any = field(default=None, compare=False)

    @staticmethod
    def make(module: str, pattern: str, colonne: str, action: str) -> "Rule":
        return Rule(module, pattern, colonne, action.upper(), like_to_regex(pattern))


# Regles appliquees en mode --dry-run (sans acces a la base de resultats) : identiques a celles du schema.
# Ici aucune : les parametres propres a chaque cluster (port, repertoires...) sont deja exclus
# par la requete inst_config.sql ; les regles du schema (table exclusion_rules) restent ajustables.
DEFAULT_RULES: List[Rule] = []


# ----------------------------------------------------------------------------
# Comparaison
# ----------------------------------------------------------------------------
@dataclass
class Diff:
    module: Module
    key: Tuple[Any, ...]
    type_diff: str                       # ONLY_R1, ONLY_R2, DIFF
    attendu: bool
    rec1: Optional[Record]
    rec2: Optional[Record]
    cols: List[str] = field(default_factory=list)

    @property
    def key_text(self) -> str:
        return ".".join(str(k) for k in self.key)


def evaluate(mod: Module, key: Tuple[Any, ...], rec1: Optional[Record], rec2: Optional[Record],
             rules: List[Rule]) -> Optional[Diff]:
    ktxt = ".".join(str(k) for k in key)
    mrules = [r for r in rules if r.module == mod.name and r.regex.match(ktxt)]
    row_ignore = any(r.colonne == "*" and r.action == "IGNORE" for r in mrules)
    row_attendu = any(r.colonne == "*" and r.action == "ATTENDU" for r in mrules)
    if row_ignore:
        return None

    if rec1 is None or rec2 is None:
        return Diff(mod, key, "ONLY_R2" if rec1 is None else "ONLY_R1", row_attendu, rec1, rec2)

    ignored = {r.colonne for r in mrules if r.action == "IGNORE" and r.colonne != "*"}
    cols = [f for f in mod.compare if f not in ignored and rec1[f] != rec2[f]]
    if not cols:
        return None
    attendu_cols = {r.colonne for r in mrules if r.action == "ATTENDU" and r.colonne != "*"}
    attendu = row_attendu or all(c in attendu_cols for c in cols)
    return Diff(mod, key, "DIFF", attendu, rec1, rec2, cols)


def _sort_key(key: Tuple[Any, ...]) -> Tuple[str, ...]:
    return tuple(str(k) for k in key)


def compare_module(mod: Module, d1: Prepared, d2: Prepared, rules: List[Rule]) -> List[Diff]:
    diffs = []
    for key in sorted(set(d1) | set(d2), key=_sort_key):
        diff = evaluate(mod, key, d1.get(key), d2.get(key), rules)
        if diff:
            diffs.append(diff)
    return diffs


def run_comparison(csv_dir: str, rules: List[Rule], ctx: Optional[Dict[str, Any]] = None) -> Dict[str, List[Diff]]:
    """Lit les 24 CSV et retourne les differences par module."""
    ctx = ctx or {}
    results: Dict[str, List[Diff]] = {}
    for mod in MODULES:
        sides = []
        for side in ("r1", "r2"):
            path = os.path.join(csv_dir, f"{side}_{mod.name}.csv")
            sides.append(build_records(mod, read_csv(path, mod.columns), path, ctx))
        results[mod.name] = compare_module(mod, sides[0], sides[1], rules)
    return results


# ----------------------------------------------------------------------------
# PostgreSQL (via le client psql)
# ----------------------------------------------------------------------------
class Pg:
    def __init__(self, host, port, dbname, user, password):
        self.psql = shutil.which("psql")
        if not self.psql:
            raise PgError("client psql introuvable dans le PATH")
        self.base = [self.psql, "-X", "-v", "ON_ERROR_STOP=1"]
        if host:
            self.base += ["-h", host]
        if port:
            self.base += ["-p", str(port)]
        if user:
            self.base += ["-U", user]
        if dbname:
            self.base += ["-d", dbname]
        self.env = dict(os.environ, PGCONNECT_TIMEOUT="10")
        if password:
            self.env["PGPASSWORD"] = password

    def _run(self, extra: List[str]) -> str:
        proc = subprocess.run(self.base + extra, env=self.env, capture_output=True, text=True)
        if proc.returncode != 0:
            msg = (proc.stderr or proc.stdout).strip().splitlines()
            raise PgError(" / ".join(msg[:3]) or f"psql a retourne le code {proc.returncode}")
        return proc.stdout

    def query(self, sql: str) -> List[Dict[str, str]]:
        out = self._run(["--csv", "-c", sql])
        return list(csv.DictReader(out.splitlines()))

    def run_script(self, path: str) -> None:
        self._run(["-1", "-q", "-o", os.devnull, "-f", path])

    def execute(self, sql: str) -> None:
        self._run(["-q", "-o", os.devnull, "-c", sql])


def sql_quote(text: str) -> str:
    return "'" + text.replace("'", "''") + "'"


def fmt(value: Any) -> str:
    if value is None:
        return PG_NULL
    if isinstance(value, bool):
        return "t" if value else "f"
    if isinstance(value, dt.datetime):
        return value.strftime("%Y-%m-%d %H:%M:%S")
    if isinstance(value, Decimal):
        return format(value, "f")
    return str(value)


def pg_row(diff: Diff, run: Dict[str, str]) -> Tuple[List[str], List[str]]:
    mod = diff.module
    cols = ["run_id", "refid", "ts_exec", "type_diff", "attendu"] + list(mod.key)
    vals = [run["run_id"], run["refid"], run["ts_exec"], diff.type_diff, "t" if diff.attendu else "f"]
    vals += [fmt(k) for k in diff.key]
    for side, rec in (("r1", diff.rec1), ("r2", diff.rec2)):
        for f in mod.pg_fields:
            cols.append(f"{side}_{f}")
            if rec is None:
                vals.append("f" if f == "present" else PG_NULL)
            else:
                vals.append(fmt(rec.get(f)))
    return cols, vals


def write_results(pg: Pg, run: Dict[str, str], results: Dict[str, List[Diff]]) -> int:
    """Insere toutes les differences et cloture le run, en une seule transaction."""
    total = sum(len(d) for d in results.values())
    tmp = tempfile.mkdtemp(prefix="compa_pg_")
    os.chmod(tmp, 0o700)
    try:
        script = []
        for mod in MODULES:
            diffs = results[mod.name]
            if not diffs:
                continue
            path = os.path.join(tmp, f"{mod.table}.csv")
            cols: List[str] = []
            with open(path, "w", encoding="utf-8", newline="") as fh:
                writer = csv.writer(fh, lineterminator="\n")
                for d in diffs:
                    cols, vals = pg_row(d, run)
                    writer.writerow(vals)
            script.append(f"\\copy {SCHEMA}.{mod.table} ({', '.join(cols)}) from '{path}' "
                          f"with (format csv, null '{PG_NULL}')")
        script.append(f"select {SCHEMA}.end_run({int(run['run_id'])}, 'TERMINE', "
                      f"{sql_quote(f'{total} ecart(s)')});")
        script_path = os.path.join(tmp, "insert.sql")
        with open(script_path, "w", encoding="utf-8") as fh:
            fh.write("\n".join(script) + "\n")
        pg.run_script(script_path)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return total


def load_run(pg: Pg, run_id: int, refid: int) -> Dict[str, str]:
    try:
        rows = pg.query(f"select run_id, refid, ts_exec from {SCHEMA}.run where run_id = {int(run_id)}")
    except PgError as exc:
        raise PgError(f"{exc} (schema absent ? executer sql/postgres/create_schema.sql)")
    if not rows:
        raise PgError(f"run_id {run_id} introuvable dans {SCHEMA}.run (le creer avec {SCHEMA}.start_run)")
    run = rows[0]
    if int(run["refid"]) != refid:
        raise PgError(f"incoherence : le run {run_id} est rattache au refid {run['refid']}, pas {refid}")
    return run


def load_rules(pg: Pg) -> List[Rule]:
    rows = pg.query(f"select module, cle_pattern, colonne, action from {SCHEMA}.exclusion_rules where actif")
    return [Rule.make(r["module"], r["cle_pattern"], r["colonne"], r["action"]) for r in rows]


def mark_error(pg: Optional[Pg], run_id: Optional[int], message: str) -> None:
    """Marque le run en ERREUR (au mieux : une panne PostgreSQL ne doit pas masquer l'erreur d'origine)."""
    if pg is None or run_id is None:
        return
    try:
        pg.execute(f"select {SCHEMA}.end_run({int(run_id)}, 'ERREUR', {sql_quote(message[:500])})")
    except PgError:
        pass


# ----------------------------------------------------------------------------
# Affichage et point d'entree
# ----------------------------------------------------------------------------
def print_summary(results: Dict[str, List[Diff]], verbose: bool) -> int:
    total = 0
    for mod in MODULES:
        diffs = results[mod.name]
        total += len(diffs)
        counts = {t: sum(1 for d in diffs if d.type_diff == t) for t in ("ONLY_R1", "ONLY_R2", "DIFF")}
        detail = ", ".join(f"{t}={n}" for t, n in counts.items() if n)
        attendus = sum(1 for d in diffs if d.attendu)
        extra = f" dont {attendus} attendu(s)" if attendus else ""
        print(f"[+] {mod.name:<12}: {len(diffs):>3} ecart(s)" + (f"  ({detail}){extra}" if detail else ""))
        if verbose:
            for d in diffs:
                line = f"      {d.type_diff:<8} {d.key_text or '(ligne unique)'}"
                if d.type_diff == "DIFF":
                    line += "  " + "; ".join(f"{c}: {d.rec1[c]!s} -> {d.rec2[c]!s}" for c in d.cols
                                            if c != "source")
                print(line)
    return total


def parse_args(argv: Optional[List[str]]) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Compare les CSV d'extraction PostgreSQL et enregistre les ecarts dans la base de resultats.")
    p.add_argument("--csv-dir", required=True, help="dossier contenant les 24 CSV r1_/r2_")
    p.add_argument("--run-id", type=int, help="run_id cree par compa_pg.start_run")
    p.add_argument("--refid", type=int, help="refid de la combinaison instance/base")
    p.add_argument("-H", "--host", help="hote PostgreSQL")
    p.add_argument("-p", "--port", type=int, help="port PostgreSQL")
    p.add_argument("-n", "--dbname", help="nom de la base PostgreSQL")
    p.add_argument("-U", "--user", help="login PostgreSQL")
    p.add_argument("-P", "--password",
                   help="mot de passe PostgreSQL (preferer PGPASSWORD ou .pgpass : un argument est visible dans ps)")
    p.add_argument("--dry-run", action="store_true",
                   help="compare et affiche sans acceder a PostgreSQL (regles d'exclusion par defaut)")
    p.add_argument("-v", "--verbose", action="store_true", help="liste chaque ecart")
    p.add_argument("--source-encoding", default="utf-8",
                   help="encodage du code source (obj_source), UTF-8 par defaut : les extractions sont en UTF-8")
    args = p.parse_args(argv)
    if not args.dry_run and (args.run_id is None or args.refid is None):
        p.error("--run-id et --refid sont obligatoires (sauf avec --dry-run)")
    return args


def main(argv: Optional[List[str]] = None) -> int:
    args = parse_args(argv)
    pg: Optional[Pg] = None
    try:
        if args.dry_run:
            rules, run = DEFAULT_RULES, None
        else:
            pg = Pg(args.host, args.port, args.dbname, args.user, args.password)
            run = load_run(pg, args.run_id, args.refid)
            rules = load_rules(pg)
    except PgError as exc:
        print(f"[-] Erreur PostgreSQL : {exc}", file=sys.stderr)
        return EXIT_PG

    try:
        results = run_comparison(args.csv_dir, rules, {"source_encoding": args.source_encoding})
    except CsvError as exc:
        print(f"[-] Erreur CSV : {exc}", file=sys.stderr)
        mark_error(pg, args.run_id, f"CSV invalide : {exc}")
        return EXIT_CSV

    total = print_summary(results, args.verbose)
    if args.dry_run:
        print(f"[i] Mode --dry-run : {total} ecart(s) detecte(s), rien n'a ete ecrit dans PostgreSQL.")
        return EXIT_OK

    try:
        write_results(pg, run, results)
    except PgError as exc:
        print(f"[-] Erreur PostgreSQL : {exc}", file=sys.stderr)
        mark_error(pg, args.run_id, f"insertion impossible : {exc}")
        return EXIT_PG
    print(f"[✓] {total} ecart(s) enregistre(s) pour run_id={args.run_id} (refid={args.refid}).")
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
