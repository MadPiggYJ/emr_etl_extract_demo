# terraform/modules/iam/outputs.tf
output "emr_service_role_arn"     { value = aws_iam_role.emr_service.arn }
output "emr_ec2_instance_profile" { value = aws_iam_instance_profile.emr_ec2.name }
