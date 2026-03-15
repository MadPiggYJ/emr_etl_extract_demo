# terraform/modules/emr/variables.tf
variable "project_name"              { type = string }
variable "release_label"             {
  type    = string
  default = "emr-6.15.0"
}
variable "private_subnet_id"         { type = string }
variable "emr_master_sg_id"          { type = string }
variable "emr_slave_sg_id"           { type = string }
variable "emr_service_access_sg_id"  { type = string }
variable "emr_service_role_arn"      { type = string }
variable "instance_profile"          { type = string }
variable "master_instance_type"      {
  type    = string
  default = "m5.large"
}
variable "core_instance_type"        {
  type    = string
  default = "m5.large"
}
variable "core_instance_count"       {
  type    = number
  default = 1
}
variable "log_bucket"                { type = string }
variable "etl_bucket"                { type = string }
variable "tags"                      {
  type    = map(string)
  default = {}
}
