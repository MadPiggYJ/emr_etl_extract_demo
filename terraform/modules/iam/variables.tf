# terraform/modules/iam/variables.tf
variable "project_name"   { type = string }
variable "etl_bucket_arn" { type = string }
variable "log_bucket_arn" { type = string }
variable "rds_secret_arn" { type = string }
variable "tags"           {
  type    = map(string)
  default = {}
}
