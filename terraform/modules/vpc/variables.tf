# terraform/modules/vpc/variables.tf
variable "vpc_cidr"       { type = string }
variable "vpc_name"       { type = string }
variable "enable_nat"     {
  type    = bool
  default = false
}
variable "aws_region"     { type = string }
variable "endpoint_sg_id" { type = string }
variable "tags"           {
  type    = map(string)
  default = {}
}
