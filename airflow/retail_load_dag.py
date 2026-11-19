"""
Retail load DAG (structure only, no data yet).

Shape:
    wait -> [ingest item_master, ingest pos_sales, ingest inventory]
         -> silver -> gold -> reconcile

One task per stage, so any stage can be retried on its own.
Every task is a placeholder (EmptyOperator) for now; replace them
with real operators later (FileSensor, Python/SQL operators, etc.).
"""

from datetime import datetime

# Works on both Airflow 3 and Airflow 2
try:
    from airflow.sdk import DAG
    from airflow.providers.standard.operators.empty import EmptyOperator
except ImportError:
    from airflow import DAG
    from airflow.operators.empty import EmptyOperator


with DAG(
    dag_id="retail_load",
    description="Retail load: wait -> ingest -> silver -> gold -> reconcile",
    start_date=datetime(2026, 1, 1),
    schedule=None,          # run manually for now
    catchup=False,
    tags=["ycotek", "retail"],
) as dag:

    # 1. Wait: files present
    wait = EmptyOperator(task_id="wait_files_present")

    # 2. Ingest (Bronze): one task per source file, run in parallel
    ingest_item_master = EmptyOperator(task_id="ingest_item_master")
    ingest_pos_sales = EmptyOperator(task_id="ingest_pos_sales")
    ingest_inventory = EmptyOperator(task_id="ingest_inventory")

    # 3. Silver: clean and check
    silver = EmptyOperator(task_id="silver_clean_and_check")

    # 4. Gold: dimensions, then facts
    gold = EmptyOperator(task_id="gold_dimensions_then_facts")

    # 5. Reconcile: tie back to source
    reconcile = EmptyOperator(task_id="reconcile_tie_back_to_source")

    # Dependencies
    ingest_tasks = [ingest_item_master, ingest_pos_sales, ingest_inventory]

    wait >> ingest_tasks
    ingest_tasks >> silver
    silver >> gold >> reconcile