# terraform/modules/emr/main.tf

resource "aws_emr_cluster" "main" {
  name          = "${var.project_name}-cluster"
  release_label = var.release_label
  applications  = ["Spark", "Hadoop"]

  service_role = var.emr_service_role_arn

  ec2_attributes {
    subnet_id                         = var.private_subnet_id # EMR 部署 所在子网
    emr_managed_master_security_group = var.emr_master_sg_id # EMR master node上的sg
    emr_managed_slave_security_group  = var.emr_slave_sg_id # EMR slave node上的sg
    # service_access_security_group 私有子网必须设置，否则 EMR 控制平面无法管理集群
    service_access_security_group     = var.emr_service_access_sg_id
    instance_profile                  = var.instance_profile
    # 不设置 key_name — 通过 SSM Session Manager 登录，无需 key pair
  }

  master_instance_group {
    instance_type = var.master_instance_type  # m5.large
  }

  core_instance_group {
    instance_type  = var.core_instance_type   # m5.large
    instance_count = var.core_instance_count  # 1
  }

  log_uri = "s3://${var.log_bucket}/emr/${var.project_name}/" # log记录层级

  configurations_json = jsonencode([
    {
      Classification = "spark-defaults"
      Properties = {
        "spark.executor.memory"      = "2g"
        "spark.driver.memory"        = "2g"
        "spark.sql.adaptive.enabled" = "true"
      }
    }
  ])

  # Bootstrap: 安装 PostgreSQL JDBC driver
  bootstrap_action {
    name = "install-jdbc-driver"
    path = "s3://${var.etl_bucket}/bootstrap/install_deps.sh"
  }

  # 空闲 1 小时后自动关闭，避免忘记关机产生费用
  auto_termination_policy {
    idle_timeout = 3600
  }

  tags = merge(var.tags, { Name = "${var.project_name}-emr" })
}
