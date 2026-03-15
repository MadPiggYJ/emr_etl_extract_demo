# terraform/modules/secrets/main.tf
# Generate a random password and store full DB connection info in Secrets Manager
# secret manager 和 system manager parameter 是两套系统 前者存credential更好 后者存配置参数更好

resource "random_password" "db" {
  length           = 24
  special          = true
  override_special = "!#$%&*()-_=+[]{}?"  # Exclude chars that break JDBC URLs # 用random服务 随机生成24位密码
}

resource "aws_secretsmanager_secret" "rds" {
  name                    = "${var.project_name}/rds/${var.db_name}"
  description             = "RDS PostgreSQL credentials for ${var.project_name}"
  recovery_window_in_days = 0  # Immediate delete in dev; set 7 in prod

  tags = var.tags
} # 创建secret 容器 里面没有任何值

resource "aws_secretsmanager_secret_version" "rds" {
  secret_id = aws_secretsmanager_secret.rds.id
  secret_string = jsonencode({
    host     = var.rds_endpoint
    port     = var.rds_port
    dbname   = var.db_name
    username = var.db_username
    password = random_password.db.result
  })
} # 创建一版value, 支持versioning
