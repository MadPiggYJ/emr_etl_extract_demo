#!/usr/bin/env python3
"""
spark_sql_queries.py
====================
Standalone SparkSQL script — run interactively on EMR primary node.
Demonstrates SparkSQL as an alternative to the PySpark DataFrame API.

Usage:
    # Copy script to EMR primary node, then:
    spark-submit \
        --jars /usr/lib/spark/jars/postgresql-42.7.3.jar \
        spark_sql_queries.py \
        --secret-name prod/rds/orders_db \
        --region ap-southeast-2

Interactive pyspark shell alternative:
    pyspark --jars /usr/lib/spark/jars/postgresql-42.7.3.jar
    # Then paste the SparkSQL blocks below one at a time
"""

import argparse
import json
import logging
import sys

import boto3
from pyspark.sql import SparkSession

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger("spark_sql")


def get_secret(secret_name: str, region: str) -> dict:
    client = boto3.client("secretsmanager", region_name=region)
    resp = client.get_secret_value(SecretId=secret_name)
    return json.loads(resp["SecretString"])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--secret-name", required=True)
    parser.add_argument("--region", default="ap-southeast-2")
    args = parser.parse_args()

    secret = get_secret(args.secret_name, args.region)
    jdbc_url = f"jdbc:postgresql://{secret['host']}:{secret['port']}/{secret['dbname']}"

    spark = (
        SparkSession.builder
        .appName("emr-sparksql-demo")
        .getOrCreate()
    )
    spark.sparkContext.setLogLevel("WARN")

    # ── Load table into Spark temp view ──────────────────────────────────────
    logger.info("Loading ecommerce.orders via JDBC …")
    (
        spark.read.format("jdbc")
        .option("url", jdbc_url)
        .option("dbtable", "ecommerce.orders")
        .option("user", secret["username"])
        .option("password", secret["password"])
        .option("driver", "org.postgresql.Driver")
        .option("numPartitions", "4")
        .option("partitionColumn", "order_id")
        .option("lowerBound", "1")
        .option("upperBound", "1000")
        .load()
        .createOrReplaceTempView("orders")
    )
    logger.info("Temp view 'orders' registered.")

    # ════════════════════════════════════════════════════════════════════════
    # Query 1 — Basic extraction + schema verification
    # ════════════════════════════════════════════════════════════════════════
    print("\n" + "="*60)
    print("Query 1: Row count & schema check")
    print("="*60)
    spark.sql("SELECT COUNT(*) AS total_rows FROM orders").show()
    spark.sql("DESCRIBE orders").show(30, truncate=False)

    # ════════════════════════════════════════════════════════════════════════
    # Query 2 — Revenue breakdown by order status
    # ════════════════════════════════════════════════════════════════════════
    print("\n" + "="*60)
    print("Query 2: Revenue by order_status")
    print("="*60)
    spark.sql("""
        SELECT
            order_status,
            COUNT(*)                          AS order_count,
            ROUND(SUM(order_amount), 2)       AS total_revenue,
            ROUND(AVG(order_amount), 2)       AS avg_order_value,
            ROUND(MIN(order_amount), 2)       AS min_order,
            ROUND(MAX(order_amount), 2)       AS max_order
        FROM orders
        GROUP BY order_status
        ORDER BY total_revenue DESC
    """).show(truncate=False)

    # ════════════════════════════════════════════════════════════════════════
    # Query 3 — Monthly trend (delivered orders only)
    # ════════════════════════════════════════════════════════════════════════
    print("\n" + "="*60)
    print("Query 3: Monthly revenue trend (delivered)")
    print("="*60)
    spark.sql("""
        SELECT
            DATE_FORMAT(order_date, 'yyyy-MM') AS month,
            COUNT(*)                           AS orders,
            ROUND(SUM(order_amount), 2)        AS revenue,
            ROUND(AVG(customer_rating), 2)     AS avg_rating
        FROM orders
        WHERE order_status = 'delivered'
          AND customer_rating IS NOT NULL
        GROUP BY month
        ORDER BY month DESC
        LIMIT 12
    """).show(truncate=False)

    # ════════════════════════════════════════════════════════════════════════
    # Query 4 — JSONB product_metadata: category analysis
    # (product_metadata loaded as string; use get_json_object)
    # ════════════════════════════════════════════════════════════════════════
    print("\n" + "="*60)
    print("Query 4: Product category breakdown (from JSONB)")
    print("="*60)
    spark.sql("""
        SELECT
            get_json_object(product_metadata, '$.category') AS category,
            COUNT(*)                                         AS orders,
            ROUND(SUM(order_amount), 2)                      AS revenue,
            ROUND(AVG(CAST(
                get_json_object(product_metadata, '$.quantity') AS INT
            )), 2)                                           AS avg_qty
        FROM orders
        WHERE product_metadata IS NOT NULL
        GROUP BY category
        ORDER BY revenue DESC
    """).show(truncate=False)

    # ════════════════════════════════════════════════════════════════════════
    # Query 5 — Repeat vs new customer spend comparison
    # ════════════════════════════════════════════════════════════════════════
    print("\n" + "="*60)
    print("Query 5: Repeat vs new customer behaviour")
    print("="*60)
    spark.sql("""
        SELECT
            CASE WHEN is_repeat_customer THEN 'Repeat' ELSE 'New' END AS customer_type,
            COUNT(*)                       AS orders,
            ROUND(AVG(order_amount), 2)    AS avg_spend,
            ROUND(AVG(customer_rating), 2) AS avg_rating,
            SUM(CASE WHEN promo_codes IS NOT NULL THEN 1 ELSE 0 END) AS used_promo
        FROM orders
        GROUP BY is_repeat_customer
    """).show(truncate=False)

    # ════════════════════════════════════════════════════════════════════════
    # Query 6 — Window function: running total by date
    # ════════════════════════════════════════════════════════════════════════
    print("\n" + "="*60)
    print("Query 6: Running revenue total (window function)")
    print("="*60)
    spark.sql("""
        SELECT
            order_date,
            daily_revenue,
            ROUND(SUM(daily_revenue) OVER (
                ORDER BY order_date
                ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
            ), 2) AS running_total
        FROM (
            SELECT
                order_date,
                ROUND(SUM(order_amount), 2) AS daily_revenue
            FROM orders
            WHERE order_status IN ('delivered', 'shipped')
            GROUP BY order_date
        ) daily
        ORDER BY order_date DESC
        LIMIT 20
    """).show(truncate=False)

    logger.info("All SparkSQL queries complete.")
    spark.stop()


if __name__ == "__main__":
    main()
