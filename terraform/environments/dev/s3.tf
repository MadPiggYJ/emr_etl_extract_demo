# ── S3 Buckets ────────────────────────────────────────────────────────────────
# 2个S3 一个存数据/bootstrap/python脚本 一个存log 
resource "aws_s3_bucket" "etl" {
  bucket = "${local.project_name}-etl-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket" "logs" {
  bucket = "${local.project_name}-logs-${data.aws_caller_identity.current.account_id}"
}


resource "aws_s3_bucket_public_access_block" "etl" {
  bucket                  = aws_s3_bucket.etl.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_public_access_block" "logs" {
  bucket                  = aws_s3_bucket.logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_object" "pyspark_script" {
  bucket = aws_s3_bucket.etl.id
  key    = "scripts/emr_extract.py"
  source = "${path.module}/../../../pyspark/emr_extract.py"
  etag   = filemd5("${path.module}/../../../pyspark/emr_extract.py")
}

resource "aws_s3_object" "pyspark_script_sql" {
  bucket = aws_s3_bucket.etl.id
  key    = "scripts/spark_sql_queries.py"
  source = "${path.module}/../../../pyspark//spark_sql_queries.py"
  etag   = filemd5("${path.module}/../../../pyspark//spark_sql_queries.py")
}

resource "aws_s3_object" "jdbc_driver" {
  bucket = aws_s3_bucket.etl.id
  key    = "bootstrap/postgresql-42.7.3.jar"
  source = "${path.module}/../../../bootstrap/postgresql-42.7.3.jar"
  etag   = filemd5("${path.module}/../../../bootstrap/postgresql-42.7.3.jar")
}

resource "aws_s3_object" "bootstrap" {
  bucket = aws_s3_bucket.etl.id
  key    = "bootstrap/install_deps.sh"
  content = templatefile("${path.module}/../../../bootstrap/install_deps.sh.tftpl", {
    etl_bucket = aws_s3_bucket.etl.id
  })
  etag = md5(templatefile("${path.module}/../../../bootstrap/install_deps.sh.tftpl", {
    etl_bucket = aws_s3_bucket.etl.id
  }))
}

