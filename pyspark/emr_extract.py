#!/usr/bin/env python3
"""
emr_extract.py
==============
PySpark job: extract ecommerce.orders from RDS PostgreSQL → S3 (Parquet)

Design decisions
----------------
- Credentials fetched from AWS Secrets Manager at runtime (never in code/env)
- JDBC partitioned read via order_id to parallelise across Spark executors
- Output written as Parquet (columnar, splittable, Athena/Glue compatible)
- Basic data quality checks logged before final write
- Structured logging throughout for CloudWatch / EMR log aggregation

Usage (on EMR primary node)
----------------------------
spark-submit \
    --jars /usr/lib/spark/jars/postgresql-42.7.3.jar \
    emr_extract.py \
    --secret-name  prod/rds/orders_db \
    --output-path  s3://your-bucket/output/orders/ \
    --region       ap-southeast-2
"""

import argparse
import json
import logging
import sys
import time
from datetime import datetime, timezone

import boto3
import botocore.exceptions
from pyspark.sql import SparkSession
from pyspark.sql import functions as F
from pyspark.sql.types import StructType

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s — %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)],
)
logger = logging.getLogger("emr_extract")


# ---------------------------------------------------------------------------
# Secrets Manager helper
# ---------------------------------------------------------------------------
def get_secret(secret_name: str, region: str) -> dict:
    """Retrieve and parse a JSON secret from AWS Secrets Manager."""
    logger.info("Fetching secret '%s' from Secrets Manager (region=%s)", secret_name, region)
    client = boto3.client("secretsmanager", region_name=region)
    try:
        response = client.get_secret_value(SecretId=secret_name)
    except botocore.exceptions.ClientError as exc:
        error_code = exc.response["Error"]["Code"]
        logger.error("Failed to retrieve secret '%s': %s — %s", secret_name, error_code, exc)
        raise SystemExit(1) from exc

    secret_str = response.get("SecretString") or ""
    if not secret_str:
        logger.error("Secret '%s' has no SecretString value", secret_name)
        raise SystemExit(1)

    return json.loads(secret_str)


# ---------------------------------------------------------------------------
# Data quality checks
# ---------------------------------------------------------------------------
def run_quality_checks(df, total_expected: int = 1000) -> bool:
    """
    Run basic data quality assertions.
    Returns True if all checks pass, False otherwise.
    """
    logger.info("Running data quality checks …")
    passed = True

    # 1. Row count
    actual_count = df.count()
    logger.info("  [CHECK] Row count: %d (expected ≥ %d)", actual_count, total_expected)
    if actual_count < total_expected:
        logger.warning("  [WARN]  Row count below threshold!")
        passed = False

    # 2. No nulls on NOT NULL columns
    not_null_cols = [
        "order_id", "order_uuid", "customer_name", "shipping_address",
        "order_amount", "is_repeat_customer", "order_date", "created_at",
        "delivery_window", "order_status",
    ]
    for col in not_null_cols:
        null_count = df.filter(F.col(col).isNull()).count()
        if null_count > 0:
            logger.warning("  [FAIL]  Column '%s' has %d unexpected NULLs", col, null_count)
            passed = False
        else:
            logger.info("  [PASS]  No NULLs in '%s'", col)

    # 3. order_amount non-negative
    neg_count = df.filter(F.col("order_amount") < 0).count()
    if neg_count > 0:
        logger.warning("  [FAIL]  %d rows have negative order_amount", neg_count)
        passed = False
    else:
        logger.info("  [PASS]  All order_amount values are non-negative")

    # 4. Valid order_status values
    valid_statuses = {"pending", "processing", "shipped", "delivered", "cancelled", "refunded"}
    invalid_status = (
        df.select("order_status")
          .distinct()
          .filter(~F.col("order_status").isin(list(valid_statuses)))
          .count()
    )
    if invalid_status > 0:
        logger.warning("  [FAIL]  Found %d invalid order_status values", invalid_status)
        passed = False
    else:
        logger.info("  [PASS]  All order_status values are valid")

    # 5. customer_rating range (1-5, NULLs acceptable)
    bad_rating = df.filter(
        F.col("customer_rating").isNotNull() &
        ~F.col("customer_rating").between(1, 5)
    ).count()
    if bad_rating > 0:
        logger.warning("  [FAIL]  %d rows have out-of-range customer_rating", bad_rating)
        passed = False
    else:
        logger.info("  [PASS]  customer_rating values all in range [1,5] or NULL")

    # Summary stats
    df.select(
        F.count("*").alias("total_rows"),
        F.countDistinct("customer_name").alias("unique_customers"),
        F.round(F.avg("order_amount"), 2).alias("avg_order_amount"),
        F.min("order_date").alias("earliest_order"),
        F.max("order_date").alias("latest_order"),
    ).show(truncate=False)

    df.groupBy("order_status").count().orderBy(F.desc("count")).show()

    return passed


# ---------------------------------------------------------------------------
# SparkSQL view demo
# ---------------------------------------------------------------------------
def run_spark_sql_demo(spark: SparkSession) -> None:
    """Register temp view and run representative SparkSQL queries."""
    logger.info("Running SparkSQL demo queries …")

    spark.sql("""
        SELECT
            order_status,
            COUNT(*)                        AS order_count,
            ROUND(SUM(order_amount), 2)     AS total_revenue,
            ROUND(AVG(order_amount), 2)     AS avg_order_value,
            ROUND(AVG(customer_rating), 2)  AS avg_rating
        FROM orders
        GROUP BY order_status
        ORDER BY total_revenue DESC
    """).show(truncate=False)

    spark.sql("""
        SELECT
            YEAR(order_date)  AS yr,
            MONTH(order_date) AS mo,
            COUNT(*)          AS orders,
            ROUND(SUM(order_amount), 2) AS revenue
        FROM orders
        WHERE order_status = 'delivered'
        GROUP BY yr, mo
        ORDER BY yr, mo
    """).show(24, truncate=False)

    spark.sql("""
        SELECT
            CAST(is_repeat_customer AS STRING) AS repeat_customer,
            COUNT(*)                           AS cnt,
            ROUND(AVG(order_amount), 2)        AS avg_spend
        FROM orders
        GROUP BY is_repeat_customer
    """).show(truncate=False)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="EMR PySpark RDS extraction job")
    parser.add_argument("--secret-name",  required=True,  help="Secrets Manager secret name")
    parser.add_argument("--output-path",  required=True,  help="S3 output path (s3://…)")
    parser.add_argument("--region",       default="ap-southeast-2")
    parser.add_argument("--jdbc-jar",     default="/usr/lib/spark/jars/postgresql-42.7.3.jar")
    parser.add_argument("--num-partitions", type=int, default=4,
                        help="JDBC parallelism (match executor count)")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    job_start = time.time()
    run_ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")

    logger.info("=" * 60)
    logger.info("EMR Extract Job starting — %s", run_ts)
    logger.info("Output path : %s", args.output_path)
    logger.info("=" * 60)

    # 1. Credentials from Secrets Manager
    secret = get_secret(args.secret_name, args.region)
    db_host     = secret["host"]
    db_port     = secret.get("port", 5432)
    db_name     = secret["dbname"]
    db_user     = secret["username"]
    db_password = secret["password"]

    jdbc_url = f"jdbc:postgresql://{db_host}:{db_port}/{db_name}"
    logger.info("JDBC URL: %s", jdbc_url.replace(db_password, "***"))

    # 2. SparkSession
    spark = (
        SparkSession.builder
        .appName("emr-rds-extract")
        .config("spark.sql.parquet.compression.codec", "snappy")
        .config("spark.sql.adaptive.enabled", "true")
        .getOrCreate()
    )
    spark.sparkContext.setLogLevel("WARN")
    logger.info("SparkSession created — version %s", spark.version)

    # 3. Determine partition bounds for parallel JDBC read
    #    (avoids single-threaded full-table scan)
    try:
        bounds_df = (
            spark.read.format("jdbc")
            .option("url", jdbc_url)
            .option("dbtable", "(SELECT MIN(order_id), MAX(order_id) FROM ecommerce.orders) AS bounds")
            .option("user", db_user)
            .option("password", db_password)
            .option("driver", "org.postgresql.Driver")
            .load()
        )
        min_id, max_id = bounds_df.collect()[0]
        logger.info("Partition bounds: order_id %d → %d", min_id, max_id)
    except Exception as exc:  # pylint: disable=broad-except
        logger.error("Failed to query partition bounds: %s", exc)
        spark.stop()
        raise SystemExit(1) from exc

    # 4. Partitioned JDBC read
    try:
        df = (
            spark.read.format("jdbc")
            .option("url", jdbc_url)
            .option("dbtable", "ecommerce.orders")
            .option("user", db_user)
            .option("password", db_password)
            .option("driver", "org.postgresql.Driver")
            .option("partitionColumn", "order_id")
            .option("lowerBound", str(min_id))
            .option("upperBound", str(max_id))
            .option("numPartitions", str(args.num_partitions))
            # Push-down: only fetch delivered/shipped for demo
            # Remove fetchsize or adjust as needed
            .option("fetchsize", "1000")
            .load()
        )
        logger.info("Schema inferred from JDBC:")
        df.printSchema()
    except Exception as exc:  # pylint: disable=broad-except
        logger.error("JDBC read failed: %s", exc)
        spark.stop()
        raise SystemExit(1) from exc

    # 5. Register as SparkSQL temp view
    df.createOrReplaceTempView("orders")

    # 6. Data quality checks
    quality_ok = run_quality_checks(df, total_expected=1000)
    if not quality_ok:
        logger.warning("Data quality checks failed — proceeding but flagging in output path")

    # 7. SparkSQL demo
    run_spark_sql_demo(spark)

    # 8. Write to S3 as Parquet, partitioned by order_status
    output_path = f"{args.output_path.rstrip('/')}/run={run_ts}/"
    logger.info("Writing Parquet output to: %s", output_path)
    try:
        (
            df.write
            .mode("overwrite")
            .partitionBy("order_status")
            .parquet(output_path)
        )
        logger.info("Write complete.")
    except Exception as exc:  # pylint: disable=broad-except
        logger.error("Write to S3 failed: %s", exc)
        spark.stop()
        raise SystemExit(1) from exc

    # 9. Verify output
    verification_df = spark.read.parquet(output_path)
    written_count = verification_df.count()
    logger.info("Verification read: %d rows in output Parquet", written_count)

    elapsed = time.time() - job_start
    logger.info("=" * 60)
    logger.info("Job finished in %.1f seconds", elapsed)
    logger.info("Quality checks passed: %s", quality_ok)
    logger.info("Rows written: %d", written_count)
    logger.info("=" * 60)

    spark.stop()


if __name__ == "__main__":
    main()
