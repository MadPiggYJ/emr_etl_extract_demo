# terraform/modules/emr/outputs.tf
output "cluster_id"        { value = aws_emr_cluster.main.id }
output "master_public_dns" { value = aws_emr_cluster.main.master_public_dns }
