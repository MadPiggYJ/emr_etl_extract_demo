# terraform/modules/rds/main.tf
# PostgreSQL 15 in private subnets — no public accessibility

resource "aws_db_subnet_group" "main" {
  name       = "${var.project_name}-db-subnet-group"
  subnet_ids = var.private_subnet_ids
  tags       = merge(var.tags, { Name = "${var.project_name}-db-subnet-group" })
} # 给rds分配vpc subnet # ec2可以直接指定，但rds为了failover需要又standby在其他的subnet

resource "aws_db_instance" "postgres" {
  identifier        = "${var.project_name}-postgres"
  engine            = "postgres"
  engine_version    = "15"
  instance_class    = var.db_instance_class
  allocated_storage = var.allocated_storage
  storage_type      = "gp3"
  storage_encrypted = true  # Encryption at rest

  db_name  = var.db_name
  username = var.db_username
  password = var.db_password  # Passed in from Secrets Manager random_password

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [var.rds_sg_id]
  multi_az = false # free tier 没有 multi az

  # Security hardening
  publicly_accessible    = false
  deletion_protection    = false  # Set true in prod
  skip_final_snapshot    = true   # Set false in prod
  backup_retention_period = 0     # Set 7+ in prod

  # Parameter group: force SSL
  parameter_group_name = aws_db_parameter_group.force_ssl.name

  tags = merge(var.tags, { Name = "${var.project_name}-postgres" })
}

resource "aws_db_parameter_group" "force_ssl" {
  name   = "${var.project_name}-pg15-ssl"
  family = "postgres15"

  parameter {
    name         = "rds.force_ssl"
    value        = "1"
    apply_method = "pending-reboot"
  }

  tags = var.tags
}
