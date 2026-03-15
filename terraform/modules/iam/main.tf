# terraform/modules/iam/main.tf

# ── EMR Service Role ──────────────────────────────────────────────────────────
# EMR 有两层role 1.Service role -> EMR控制平面对EMR集群的管理权限 管理EC2 / SG / EBS -> 建立集群 分配任务 2.instance role EMR EC2 instance对数据操作的权限 运行任务
data "aws_iam_policy_document" "emr_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["elasticmapreduce.amazonaws.com"]
    }
  }
} # 解析policy json

resource "aws_iam_role" "emr_service" {
  name               = "${var.project_name}-emr-service-role"
  assume_role_policy = data.aws_iam_policy_document.emr_assume.json
  tags               = var.tags
} # 谁可以来assume这个role "elasticmapreduce.amazonaws.com" EMR service -> EMR Trust policy

resource "aws_iam_role_policy_attachment" "emr_service" {
  role       = aws_iam_role.emr_service.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonElasticMapReduceRole"
} # EMR 控制平面的权限允许 Permission Policy

# ── EC2 Instance Profile (attached to EMR nodes) ──────────────────────────────
# EMR EC2 instance 权限 包括 EMR base/S3/secrets/ssm
data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "emr_ec2" {
  name               = "${var.project_name}-emr-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
  tags               = var.tags
} # 允许ec2 assume emr_ec2 role

# EMR base policy -> EC2之间的通信 EC2 bootstrap运行/cloudwatch log/访问EMR内部S3/标签化EC2
resource "aws_iam_role_policy_attachment" "emr_ec2_base" {
  role       = aws_iam_role.emr_ec2.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonElasticMapReduceforEC2Role"
} # 给emr_ec2 role attach emr_ec2_base 权限 官方policy

# SSM Session Manager — 允许通过控制台/CLI 登录，无需 key pair 和开放 22 端口
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.emr_ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
} # 给emr_ec2 attach ssm 权限 官方policy

# S3 访问：仅限 ETL bucket 和 log bucket，最小权限 ETL 读写删 log 写
data "aws_iam_policy_document" "emr_ec2_s3" {
  statement {
    sid    = "AllowETLBucket"
    effect = "Allow"
    actions = [
      "s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"
    ]
    resources = [
      var.etl_bucket_arn,
      "${var.etl_bucket_arn}/*",
    ]
  }
  statement {
    sid    = "AllowLogBucket"
    effect = "Allow"
    actions = [
      "s3:GetBucketLocation",
      "s3:ListBucket",
    ]
    resources = [var.log_bucket_arn]
  }

  statement {
    sid    = "AllowLogObjects"
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:PutObjectAcl",
      "s3:GetObject",
    ]
    resources = ["${var.log_bucket_arn}/emr/*"]
  }
} # 自定义s3 bucket policy

resource "aws_iam_role_policy" "emr_ec2_s3" {
  name   = "emr-ec2-s3-access"
  role   = aws_iam_role.emr_ec2.id
  policy = data.aws_iam_policy_document.emr_ec2_s3.json
} # 给emr_ec2 role attach s3 权限

# Secrets Manager：只读取指定的 RDS secret
data "aws_iam_policy_document" "emr_ec2_secrets" {
  statement {
    sid    = "ReadRDSSecret"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = [var.rds_secret_arn]
  }
}

resource "aws_iam_role_policy" "emr_ec2_secrets" {
  name   = "emr-ec2-secrets-access"
  role   = aws_iam_role.emr_ec2.id
  policy = data.aws_iam_policy_document.emr_ec2_secrets.json
} # 给 emr_ec2 role attach secret 权限

# ec2 assume role 不能直接 assume，需要把iam role 包裹进instance profile
resource "aws_iam_instance_profile" "emr_ec2" {
  name = "${var.project_name}-emr-ec2-profile"
  role = aws_iam_role.emr_ec2.name
  tags = var.tags
}
