# terraform/modules/rds/outputs.tf

output "endpoint" { value = aws_db_instance.postgres.address }
output "port"     { value = aws_db_instance.postgres.port }
output "db_name"  { value = aws_db_instance.postgres.db_name }
