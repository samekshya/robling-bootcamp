"""
Tests for the retail_load_2_3 DAG.

Run inside the Airflow container (see README):
    docker compose cp tests/. airflow-worker:/tmp/tests
    docker compose exec airflow-worker python -m unittest discover -s /tmp/tests -v
"""

import os
import re
import unittest
from pathlib import Path

from airflow.models import DagBag

DAG_ID = "retail_load_2_3"
DAGS_DIR = Path(os.environ["AIRFLOW_HOME"]) / "dags"
DAG_FILE = DAGS_DIR / "retail_load_2_3.py"
SQL_DIR = Path(os.environ["AIRFLOW_HOME"]) / "include" / "sql"


class TestRetailLoadDag(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.dagbag = DagBag(dag_folder=str(DAGS_DIR))
        cls.dag = cls.dagbag.get_dag(DAG_ID)

    # --- the DAG parses ---------------------------------------------------
    def test_no_import_errors(self):
        self.assertEqual(self.dagbag.import_errors, {}, self.dagbag.import_errors)

    def test_dag_is_loaded(self):
        self.assertIsNotNone(self.dag, f"{DAG_ID} not found in {DAGS_DIR}")

    # --- no cycles ----------------------------------------------------------
    def test_no_cycles(self):
        # topological_sort raises if the graph has a cycle
        order = self.dag.topological_sort()
        self.assertEqual(len(order), len(self.dag.tasks))

    # --- retries set --------------------------------------------------------
    def test_every_task_has_retries(self):
        for t in self.dag.tasks:
            with self.subTest(task=t.task_id):
                self.assertGreaterEqual(t.retries, 1)

    # --- expected stages, in the right order --------------------------------
    def test_expected_tasks_exist(self):
        expected = {
            "setup", "wait_for_files", "ingest_file",
            "silver.fiscal_day", "silver.item", "silver.store",
            "silver.sales_line", "silver.inventory_position",
            "gold_dimensions.dim_year", "gold_dimensions.dim_month",
            "gold_dimensions.dim_week", "gold_dimensions.dim_day",
            "gold_dimensions.dim_catg", "gold_dimensions.dim_subcatg",
            "gold_dimensions.dim_item", "gold_dimensions.dim_area",
            "gold_dimensions.dim_regn", "gold_dimensions.dim_district",
            "gold_dimensions.dim_locn",
            "gold_facts.fct_sales", "gold_facts.fct_inventory",
            "reconcile",
        }
        self.assertTrue(expected.issubset(set(self.dag.task_ids)),
                        expected - set(self.dag.task_ids))

    def test_stage_order(self):
        upstream = lambda tid: self.dag.get_task(tid).get_flat_relative_ids(upstream=True)
        self.assertIn("wait_for_files", upstream("ingest_file"))
        self.assertIn("ingest_file", upstream("silver.sales_line"))
        self.assertIn("gold_dimensions.dim_item", upstream("gold_facts.fct_sales"))
        self.assertIn("gold_dimensions.dim_locn", upstream("gold_facts.fct_inventory"))
        self.assertIn("gold_facts.fct_sales", upstream("reconcile"))
        self.assertIn("gold_facts.fct_inventory", upstream("reconcile"))
        self.assertEqual(self.dag.leaves[0].task_id, "reconcile")

    # --- scheduling safety ----------------------------------------------------
    def test_sensor_has_timeout(self):
        sensor = self.dag.get_task("wait_for_files")
        self.assertTrue(0 < sensor.partial_kwargs.get("timeout", 0) <= 6 * 60 * 60)

    def test_one_run_at_a_time(self):
        self.assertEqual(self.dag.max_active_runs, 1)

    # --- no hard-coding in the DAG file --------------------------------------
    def test_no_credentials_paths_or_tables_in_dag_file(self):
        text = DAG_FILE.read_text(encoding="utf-8")
        forbidden = [
            r"password\s*=", r"account\s*=", r"lhensjd", r"AIRFLOW_USER",   # credentials
            r"/opt/airflow", r"[A-Za-z]:\\\\",                              # paths
            r"\bRETAIL_DW\.", r"\bSILVER\.", r"\bBRONZE\.",                  # table names
        ]
        for pattern in forbidden:
            with self.subTest(pattern=pattern):
                self.assertIsNone(re.search(pattern, text), f"found {pattern!r} in the DAG file")

    # --- every SQL file the DAG uses exists ---------------------------------
    def test_sql_files_exist(self):
        text = DAG_FILE.read_text(encoding="utf-8")
        files = set(re.findall(r'"((?:silver|gold|reconcile)/[a-z_]+\.sql)"', text))
        files.add("00_setup.sql")
        self.assertGreater(len(files), 15)
        for f in files:
            with self.subTest(sql=f):
                self.assertTrue((SQL_DIR / f).is_file(), f"missing {SQL_DIR / f}")


if __name__ == "__main__":
    unittest.main()
