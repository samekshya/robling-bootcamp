# Data Engineering Bootcamp: Module 2

Retail data warehouse for Northline Retail, built in Snowflake and orchestrated with Apache Airflow.

| Folder | Assignment | Contents |
|---|---|---|
| `assignment_2_1` | 2.1 Dimension and fact model | Snowflake DDL (15 tables), ER diagram, model notes |
| `assignment_2_2` | 2.2 Medallion architecture | Layer inventory, architecture diagram, notes (layer contracts, quality gates, retention, reload policy) |
| `orchestration_1_dag_structure` | Orchestration 1 | Airflow DAG with the retail load structure (wait, ingest, silver, gold, reconcile) |
| `orchestration_2_snowflake_load` | Orchestration 2 | Airflow DAG that waits for a `.COMPLETE` file and loads CSV files into Snowflake |

**Tools:** Snowflake, Apache Airflow 3 (Docker), draw.io, Mermaid.