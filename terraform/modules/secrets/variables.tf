# terraform/modules/secrets/variables.tf
variable "project_name"  { type = string }
variable "rds_endpoint"  { type = string }
variable "rds_port"      {
  type    = number
  default = 5432
}
variable "db_name"       { type = string }
variable "db_username"   { type = string }
variable "tags"          {
  type    = map(string)
  default = {}
}

# terraform/modules/secrets/outputs.tf
