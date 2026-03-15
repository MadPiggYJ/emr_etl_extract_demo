# terraform/environments/dev/main.tf

terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = var.aws_region
  default_tags { tags = local.common_tags }
}


data "aws_caller_identity" "current" {}



# ══════════════════════════════════════════════════════════════════════════════
# Modules
# ══════════════════════════════════════════════════════════════════════════════

module "vpc" {
  source         = "../../modules/vpc"
  vpc_cidr       = var.vpc_cidr
  vpc_name       = local.project_name
  enable_nat     = var.enable_nat
  aws_region     = var.aws_region
  endpoint_sg_id = aws_security_group.endpoints.id
  tags           = local.common_tags
}

module "secrets" {
  source       = "../../modules/secrets"
  project_name = local.project_name
  rds_endpoint = module.rds.endpoint
  rds_port     = module.rds.port
  db_name      = var.db_name
  db_username  = var.db_username
  tags         = local.common_tags
  depends_on   = [module.vpc]
}

module "rds" {
  source             = "../../modules/rds"
  project_name       = local.project_name
  private_subnet_ids = module.vpc.private_subnet_ids
  rds_sg_id          = aws_security_group.rds.id
  db_name            = var.db_name
  db_username        = var.db_username
  db_password        = module.secrets.db_password
  db_instance_class  = var.db_instance_class
  allocated_storage  = var.db_allocated_storage
  tags               = local.common_tags
}

module "iam" {
  source         = "../../modules/iam"
  project_name   = local.project_name
  etl_bucket_arn = aws_s3_bucket.etl.arn
  log_bucket_arn = aws_s3_bucket.logs.arn
  rds_secret_arn = module.secrets.secret_arn
  tags           = local.common_tags
}

module "emr" {
  source                   = "../../modules/emr"
  project_name             = local.project_name
  release_label            = var.emr_release_label
  private_subnet_id        = module.vpc.private_subnet_ids[0]
  emr_master_sg_id         = aws_security_group.emr_master.id
  emr_slave_sg_id          = aws_security_group.emr_slave.id
  emr_service_access_sg_id = aws_security_group.emr_service_access.id
  emr_service_role_arn     = module.iam.emr_service_role_arn
  instance_profile         = module.iam.emr_ec2_instance_profile
  master_instance_type     = var.emr_master_instance_type
  core_instance_type       = var.emr_core_instance_type
  core_instance_count      = var.emr_core_instance_count
  log_bucket               = aws_s3_bucket.logs.id
  etl_bucket               = aws_s3_bucket.etl.id
  tags                     = local.common_tags

  # 确保 bootstrap 和 pyspark 脚本上传完成后再创建 EMR cluster
  # 否则 Terraform 可能并行执行，EMR bootstrap 阶段读取 S3 时脚本尚未上传
  depends_on = [
    aws_s3_object.bootstrap,
    aws_s3_object.pyspark_script,
    aws_s3_object.jdbc_driver,
  ]
}
