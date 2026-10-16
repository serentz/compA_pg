#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Tests de compare.py (bibliotheque standard uniquement).

    cd python && python3 -m unittest discover -s tests -v

Les CSV de fixtures/ sont une extraction reelle de deux clusters PostgreSQL de test
(sql/pg_test/*.sql) ; make_fixtures.sh les regenere.

Test d'integration PostgreSQL (optionnel) : definir COMPA_TEST_PG=1 ainsi que PGHOST, PGPORT,
PGUSER (et PGPASSWORD si besoin) et COMPA_TEST_DB (base ou create_schema.sql a deja ete execute).
"""
import contextlib
import io
import os
import shutil
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

import compare  # noqa: E402

FIXTURES = os.path.join(HERE, "fixtures")

EXPECTED_COUNTS = {
    "inst_config": 1, "db_size": 1, "db_options": 1, "obj_tables": 8, "obj_indexes": 5,
    "obj_code": 3, "obj_source": 5, "constraints": 5, "extensions": 2, "sequences": 1,
    "roles": 4, "grants": 19,
}
TOTAL = sum(EXPECTED_COUNTS.values())


def keys(results, module, type_diff=None):
    return {d.key_text for d in results[module] if type_diff in (None, d.type_diff)}


def module(name):
    return [m for m in compare.MODULES if m.name == name][0]


class FixturesTest(unittest.TestCase):
    def test_every_module_has_both_fixtures(self):
        self.assertEqual(len(compare.MODULES), 12)
        for m in compare.MODULES:
            for side in ("r1", "r2"):
                self.assertTrue(os.path.isfile(os.path.join(FIXTURES, f"{side}_{m.name}.csv")), m.name)


class ComparisonTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.results = compare.run_comparison(FIXTURES, compare.DEFAULT_RULES)

    def test_counts_per_module(self):
        self.assertEqual({m: len(d) for m, d in self.results.items()}, EXPECTED_COUNTS)

    def test_instance_and_db_modules(self):
        self.assertEqual(keys(self.results, "inst_config"), {"work_mem"})
        self.assertEqual(keys(self.results, "db_size"), {"schema:app"})
        self.assertEqual(keys(self.results, "db_options"), {"setting:search_path"})
        self.assertEqual(keys(self.results, "db_options", "ONLY_R1"), {"setting:search_path"})

    def test_cluster_specific_settings_are_not_extracted(self):
        with open(os.path.join(FIXTURES, "r1_inst_config.csv"), encoding="utf-8") as fh:
            names = {ln.split("|")[0] for ln in fh}
        for name in ("port", "data_directory", "config_file", "hba_file", "cluster_name", "search_path"):
            self.assertNotIn(name, names)

    def test_tables(self):
        self.assertEqual(keys(self.results, "obj_tables", "DIFF"),
                         {"app.customers.email", "app.customers.name", "app.orders.comment"})
        self.assertEqual(keys(self.results, "obj_tables", "ONLY_R1"),
                         {"app.legacy_codes.code", "app.legacy_codes.label"})
        self.assertEqual(keys(self.results, "obj_tables", "ONLY_R2"),
                         {"app.customers.phone", "app.tmp_import.id", "app.tmp_import.payload"})

    def test_table_column_attributes(self):
        by_key = {d.key_text: d for d in self.results["obj_tables"]}
        comment = by_key["app.orders.comment"]
        self.assertEqual((comment.rec1["not_null"], comment.rec2["not_null"]), ("false", "true"))
        self.assertEqual(set(comment.cols), {"not_null", "default_value"})

    def test_schema_qualification_does_not_create_false_diffs(self):
        # nextval('seq_invoice') / nextval('app.seq_invoice') : extraction faite avec search_path = pg_catalog
        self.assertNotIn("app.orders.invoice_no", keys(self.results, "obj_tables"))

    def test_indexes(self):
        self.assertEqual(keys(self.results, "obj_indexes", "DIFF"), {"app.customers.ux_customers_email"})
        self.assertEqual(keys(self.results, "obj_indexes", "ONLY_R1"),
                         {"app.legacy_codes.legacy_codes_pkey", "app.order_items.ix_items_sku"})
        self.assertEqual(keys(self.results, "obj_indexes", "ONLY_R2"),
                         {"app.orders.ix_orders_ordered_at", "app.tmp_import.tmp_import_pkey"})

    def test_code_presence(self):
        self.assertEqual(keys(self.results, "obj_code", "ONLY_R1"),
                         {"app.customers.trg_customers_audit.TR", "app.mv_sales_by_country.M"})
        self.assertEqual(keys(self.results, "obj_code", "ONLY_R2"), {"app.v_tmp_import.V"})

    def test_source_diff_and_identical_witness(self):
        self.assertEqual(keys(self.results, "obj_source", "DIFF"), {"app.audit_trg().F", "app.v_open_orders.V"})
        found = keys(self.results, "obj_source")
        self.assertNotIn("app.order_total(p_order integer).F", found)     # identique des deux cotes
        self.assertNotIn("app.purge_audit(p_days integer).P", found)

    def test_source_text_is_kept(self):
        d = {x.key_text: x for x in self.results["obj_source"]}["app.audit_trg().F"]
        self.assertIn("left(TG_OP, 1)", d.rec1["source"])
        self.assertIn("TG_OP, 1", d.rec1["source"])
        self.assertNotIn("left(", d.rec2["source"])
        self.assertGreater(d.rec1["nb_lignes"], 1)

    def test_constraints(self):
        self.assertEqual(keys(self.results, "constraints", "DIFF"),
                         {"app.orders.orders_customer_id_fkey", "app.orders.orders_status_check"})
        self.assertEqual(keys(self.results, "constraints", "ONLY_R1"),
                         {"app.legacy_codes.legacy_codes_pkey", "app.order_items.order_items_order_id_fkey"})
        fk = {d.key_text: d for d in self.results["constraints"]}["app.orders.orders_customer_id_fkey"]
        self.assertIn("ON DELETE RESTRICT", fk.rec1["definition"])
        self.assertIn("ON DELETE CASCADE", fk.rec2["definition"])

    def test_extensions_and_sequences(self):
        self.assertEqual(keys(self.results, "extensions", "ONLY_R1"), {"citext"})
        self.assertEqual(keys(self.results, "extensions", "ONLY_R2"), {"hstore"})
        seq = self.results["sequences"][0]
        self.assertEqual((seq.key_text, seq.rec1["increment_by"], seq.rec2["increment_by"]), ("app.seq_batch", "5", "10"))

    def test_roles(self):
        self.assertEqual(keys(self.results, "roles", "ONLY_R1"), {"batch_user"})
        self.assertEqual(keys(self.results, "roles", "ONLY_R2"), {"reporting_user"})
        by_key = {d.key_text: d for d in self.results["roles"]}
        self.assertEqual(by_key["app_ro"].cols, ["can_login"])
        self.assertEqual(by_key["app_rw"].cols, ["conn_limit"])

    def test_grants(self):
        by_key = {d.key_text: d for d in self.results["grants"]}
        d = by_key["table.app.orders.app_ro"]
        self.assertEqual((d.rec1["privileges"], d.rec2["privileges"]), ("SELECT", "INSERT,SELECT"))
        self.assertEqual(by_key["function.app.order_total(p_order integer).PUBLIC"].type_diff, "ONLY_R2")


class RulesTest(unittest.TestCase):
    def run_with(self, rules):
        return compare.run_comparison(FIXTURES, rules)

    def test_attendu_row_rule(self):
        res = self.run_with([compare.Rule.make("roles", "%", "*", "ATTENDU")])
        self.assertTrue(all(d.attendu for d in res["roles"]))
        self.assertFalse(any(d.attendu for d in res["extensions"]))

    def test_ignore_row_rule_with_like_pattern(self):
        res = self.run_with([compare.Rule.make("obj_tables", "app.tmp_import.%", "*", "IGNORE")])
        self.assertEqual(len(res["obj_tables"]), 6)
        self.assertNotIn("app.tmp_import.id", keys(res, "obj_tables"))

    def test_ignore_column_rule(self):
        # app.customers.name ne differe que par type_name : ignorer cette colonne le fait disparaitre
        res = self.run_with([compare.Rule.make("obj_tables", "app.customers.name", "type_name", "IGNORE")])
        self.assertNotIn("app.customers.name", keys(res, "obj_tables"))

    def test_attendu_column_rule_needs_all_columns_covered(self):
        rules = [compare.Rule.make("obj_tables", "app.orders.comment", "not_null", "ATTENDU")]
        d = {x.key_text: x for x in self.run_with(rules)["obj_tables"]}["app.orders.comment"]
        self.assertFalse(d.attendu)     # default_value differe aussi, non couvert
        rules.append(compare.Rule.make("obj_tables", "app.orders.comment", "default_value", "ATTENDU"))
        d = {x.key_text: x for x in self.run_with(rules)["obj_tables"]}["app.orders.comment"]
        self.assertTrue(d.attendu)

    def test_grants_pattern_on_composite_key(self):
        res = self.run_with([compare.Rule.make("grants", "table.app.tmp_import.%", "*", "IGNORE")])
        self.assertEqual(len(res["grants"]), 16)


class ParsingTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp)

    def write(self, name, content):
        path = os.path.join(self.tmp, name)
        with open(path, "w", encoding="utf-8", newline="") as fh:
            fh.write(content)
        return path

    def test_missing_file(self):
        with self.assertRaises(compare.CsvError):
            compare.read_csv(os.path.join(self.tmp, "absent.csv"), ["a"])

    def test_empty_file_without_header_is_an_error(self):
        with self.assertRaisesRegex(compare.CsvError, "vide"):
            compare.read_csv(self.write("e.csv", "\n  \n"), ["a"])

    def test_header_only_means_no_rows(self):
        self.assertEqual(compare.read_csv(self.write("h.csv", "a|b\n"), ["a", "b"]), [])

    def test_bad_header(self):
        with self.assertRaisesRegex(compare.CsvError, "en-tete invalide"):
            compare.read_csv(self.write("b.csv", "a|c\n1|2\n"), ["a", "b"])

    def test_wrong_column_count(self):
        with self.assertRaisesRegex(compare.CsvError, "ligne 2"):
            compare.read_csv(self.write("c.csv", "a|b\n1|2|3\n"), ["a", "b"])

    def test_null_empty_blank_lines_crlf_and_bom(self):
        path = self.write("t.csv", "﻿a|b\r\n1|NULL\r\n\r\nx|\r\n")
        rows = compare.read_csv(path, ["a", "b"])
        self.assertEqual([r for _, r in rows], [{"a": "1", "b": None}, {"a": "x", "b": ""}])

    def test_spaces_are_significant(self):
        rows = compare.read_csv(self.write("s.csv", "a|b\n sp | x\n"), ["a", "b"])
        self.assertEqual(rows[0][1], {"a": " sp ", "b": " x"})

    def test_quoted_fields_with_separator_quotes_and_newlines(self):
        path = self.write("q.csv", 'a|b|c\n"x|y"|"l1\nl2"|"q""r"\nz|1|2\n')
        rows = compare.read_csv(path, ["a", "b", "c"])
        self.assertEqual(rows[0][1], {"a": "x|y", "b": "l1\nl2", "c": 'q"r'})
        self.assertEqual(rows[1][0], 4)      # numero de ligne physique du fichier

    def test_duplicate_key(self):
        path = self.write("d.csv", "name|value|unit|source\nx|1||a\nx|2||a\n")
        mod = module("inst_config")
        with self.assertRaisesRegex(compare.CsvError, "double"):
            compare.build_records(mod, compare.read_csv(path, mod.columns), path, {})

    def test_null_key_is_rejected(self):
        path = self.write("n.csv", "name|value|unit|source\nNULL|1||a\n")
        mod = module("inst_config")
        with self.assertRaisesRegex(compare.CsvError, "NULL"):
            compare.build_records(mod, compare.read_csv(path, mod.columns), path, {})

    def test_invalid_number(self):
        path = self.write("i.csv", "item|size_mb\ndatabase|abc\n")
        mod = module("db_size")
        with self.assertRaisesRegex(compare.CsvError, "size_mb"):
            compare.build_records(mod, compare.read_csv(path, mod.columns), path, {})

    def test_timestamp_formats(self):
        iso = compare.parse_ts("2026-10-12 11:00:00")
        self.assertEqual(compare.parse_ts("2026-10-12T11:00:00"), iso)
        with self.assertRaises(ValueError):
            compare.parse_ts("pas une date")

    def test_source_normalization_ignores_line_endings_and_trailing_spaces(self):
        mod = module("obj_source")

        def prep(text):
            hexa = text.encode("utf-8").hex()
            rows = [(2, {"object_name": "p", "object_type": "P", "colid": "1", "text_hex": hexa})]
            return compare.prepare_obj_source(mod, rows, "x.csv", {})[("p", "P")]["hash"]

        self.assertEqual(prep("a  \nb\n"), prep("a\r\nb\r\n\r\n"))
        self.assertNotEqual(prep("a\nb"), prep("a\nc"))

    def test_source_chunks_are_reassembled_in_colid_order(self):
        mod = module("obj_source")
        rows = [(2, {"object_name": "p", "object_type": "P", "colid": "2", "text_hex": b"world".hex()}),
                (3, {"object_name": "p", "object_type": "P", "colid": "1", "text_hex": b"hello ".hex()})]
        rec = compare.prepare_obj_source(mod, rows, "x.csv", {})[("p", "P")]
        self.assertEqual(rec["source"], "hello world")
        rows.append((4, dict(rows[0][1])))
        with self.assertRaisesRegex(compare.CsvError, "double"):
            compare.prepare_obj_source(mod, rows, "x.csv", {})

    def test_invalid_hex(self):
        mod = module("obj_source")
        rows = [(2, {"object_name": "p", "object_type": "P", "colid": "1", "text_hex": "zz"})]
        with self.assertRaisesRegex(compare.CsvError, "hexadecimal"):
            compare.prepare_obj_source(mod, rows, "x.csv", {})


class CliTest(unittest.TestCase):
    def call(self, argv):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = compare.main(argv)
        return code, out.getvalue(), err.getvalue()

    def test_dry_run_ok(self):
        code, out, _ = self.call(["--csv-dir", FIXTURES, "--dry-run"])
        self.assertEqual(code, compare.EXIT_OK)
        self.assertIn(f"{TOTAL} ecart(s) detecte(s)", out)

    def test_missing_csv_gives_exit_2(self):
        tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, tmp)
        code, _, err = self.call(["--csv-dir", tmp, "--dry-run"])
        self.assertEqual(code, compare.EXIT_CSV)
        self.assertIn("fichier manquant", err)

    def test_run_id_required_without_dry_run(self):
        with self.assertRaises(SystemExit):
            with contextlib.redirect_stderr(io.StringIO()):
                compare.parse_args(["--csv-dir", FIXTURES])

    def test_unreachable_postgres_gives_exit_3(self):
        if not shutil.which("psql"):
            self.skipTest("psql absent")
        code, _, err = self.call(["--csv-dir", FIXTURES, "--run-id", "1", "--refid", "1",
                                  "-H", "127.0.0.1", "-p", "1", "-n", "x", "-U", "x"])
        self.assertEqual(code, compare.EXIT_PG)
        self.assertIn("PostgreSQL", err)


@unittest.skipUnless(os.environ.get("COMPA_TEST_PG") and shutil.which("psql"),
                     "definir COMPA_TEST_PG=1 (+ PGHOST/PGPORT/PGUSER, COMPA_TEST_DB) pour tester sur PostgreSQL")
class PostgresIntegrationTest(unittest.TestCase):
    """Necessite une base ou sql/postgres/create_schema.sql a ete execute."""

    def pg(self):
        return compare.Pg(os.environ.get("PGHOST"), os.environ.get("PGPORT"), os.environ["COMPA_TEST_DB"],
                          os.environ.get("PGUSER"), os.environ.get("PGPASSWORD"))

    def call(self, argv):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = compare.main(argv)
        return code, out.getvalue(), err.getvalue()

    def args(self, run_id, refid, csv_dir=FIXTURES):
        return ["--csv-dir", csv_dir, "--run-id", str(run_id), "--refid", str(refid), "-n", os.environ["COMPA_TEST_DB"]]

    def new_run(self, pg):
        refid = pg.query("select compa_pg.get_or_create_refid('TEST1','poc_pg','TEST2','poc_pg') as r")[0]["r"]
        run_id = pg.query(f"select compa_pg.start_run({refid}) as r")[0]["r"]
        return int(run_id), int(refid)

    def count_all(self, pg, run_id):
        return sum(int(pg.query(f"select count(*) as n from compa_pg.{m.table} where run_id = {run_id}")[0]["n"])
                   for m in compare.MODULES)

    def test_full_run_is_written(self):
        pg = self.pg()
        run_id, refid = self.new_run(pg)
        code, out, err = self.call(self.args(run_id, refid))
        self.assertEqual(code, compare.EXIT_OK, err)
        self.assertEqual(self.count_all(pg, run_id), TOTAL)
        run = pg.query(f"select statut, message from compa_pg.run where run_id = {run_id}")[0]
        self.assertEqual((run["statut"], run["message"]), ("TERMINE", f"{TOTAL} ecart(s)"))
        selector = pg.query(f"select libelle from compa_pg.v_run_selector where run_id = {run_id}")[0]["libelle"]
        self.assertIn("TEST1.poc_pg vs TEST2.poc_pg", selector)
        # le code multi-lignes est stocke tel quel
        src = pg.query(f"select r1_source from compa_pg.diff_obj_source where run_id = {run_id} "
                       f"and object_name = 'app.audit_trg()'")[0]["r1_source"]
        self.assertIn("INSERT INTO app.audit_log", src)
        # un champ contenant des virgules, des guillemets et des retours ligne est stocke sans alteration
        d = pg.query(f"select r1_definition from compa_pg.diff_constraints where run_id = {run_id} "
                     f"and constraint_name = 'orders_status_check'")[0]["r1_definition"]
        self.assertIn("CANCELLED", d)
        # le NULL du cote absent est bien un NULL SQL
        n = pg.query(f"select count(*) as n from compa_pg.diff_obj_tables where run_id = {run_id} "
                     f"and type_diff = 'ONLY_R1' and r2_type_name is null")[0]["n"]
        self.assertEqual(int(n), 2)
        # synthese : somme des nb = total
        n = pg.query(f"select sum(nb) as n from compa_pg.v_synthese_run where run_id = {run_id}")[0]["n"]
        self.assertEqual(int(n), TOTAL)

    def test_unknown_run_gives_exit_3(self):
        code, _, err = self.call(self.args(999999, 1))
        self.assertEqual(code, compare.EXIT_PG)
        self.assertIn("introuvable", err)

    def test_refid_mismatch_gives_exit_3(self):
        pg = self.pg()
        run_id, refid = self.new_run(pg)
        code, _, err = self.call(self.args(run_id, refid + 1000))
        self.assertEqual(code, compare.EXIT_PG)
        self.assertIn("incoherence", err)

    def test_invalid_csv_marks_run_in_error(self):
        pg = self.pg()
        run_id, refid = self.new_run(pg)
        tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, tmp)
        for name in os.listdir(FIXTURES):
            shutil.copy(os.path.join(FIXTURES, name), tmp)
        os.remove(os.path.join(tmp, "r2_db_size.csv"))
        code, _, _ = self.call(self.args(run_id, refid, tmp))
        self.assertEqual(code, compare.EXIT_CSV)
        run = pg.query(f"select statut, message from compa_pg.run where run_id = {run_id}")[0]
        self.assertEqual(run["statut"], "ERREUR")
        self.assertIn("fichier manquant", run["message"])
        self.assertEqual(self.count_all(pg, run_id), 0)

    def test_rerun_same_run_is_rejected_and_rolled_back(self):
        pg = self.pg()
        run_id, refid = self.new_run(pg)
        self.assertEqual(self.call(self.args(run_id, refid))[0], compare.EXIT_OK)
        code, _, err = self.call(self.args(run_id, refid))
        self.assertEqual(code, compare.EXIT_PG)
        self.assertEqual(self.count_all(pg, run_id), TOTAL)     # pas de doublons : la 2e insertion est annulee


if __name__ == "__main__":
    unittest.main()
