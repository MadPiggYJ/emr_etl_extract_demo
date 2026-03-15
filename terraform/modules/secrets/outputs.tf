# terraform/modules/secrets/outputs.tf

output "secret_arn"      { value = aws_secretsmanager_secret.rds.arn }
output "secret_name"     { value = aws_secretsmanager_secret.rds.name }
output "db_password"     {
  value     = random_password.db.result
  sensitive = true
}
