# terraform/environments/dev/outputs.tf

output "vpc_id" { value = module.vpc.vpc_id }
output "rds_endpoint" { value = module.rds.endpoint }
output "rds_secret_name" { value = module.secrets.secret_name }
output "emr_cluster_id" { value = module.emr.cluster_id }
output "etl_bucket" { value = aws_s3_bucket.etl.id }

output "ssm_login_command" {
  description = "通过 SSM 登录 EMR primary node（无需 key pair）"
  value       = "aws ssm start-session --target $(aws emr list-instances --cluster-id ${module.emr.cluster_id} --instance-group-types MASTER --query 'Instances[0].Ec2InstanceId' --output text) --region ${var.aws_region}"
}

output "spark_submit_command" {
  description = "在 EMR primary node 上运行的 spark-submit 命令"
  value       = <<-CMD
    spark-submit \
      --jars /usr/lib/spark/jars/postgresql-42.7.3.jar \
      /home/hadoop/emr_extract.py \
      --secret-name  ${module.secrets.secret_name} \
      --output-path  s3://${aws_s3_bucket.etl.id}/output/orders/ \
      --region       ${var.aws_region}
  CMD
}
