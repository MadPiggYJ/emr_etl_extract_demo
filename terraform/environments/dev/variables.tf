# terraform/environments/dev/variables.tf

variable "aws_region" {
  type    = string
  default = "ap-southeast-2"
}
variable "project_name" {
  type    = string
  default = "emr-etl"
}
variable "environment" {
  type    = string
  default = "dev"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}
variable "enable_nat" {
  type    = bool
  default = false
}

variable "db_name" {
  type    = string
  default = "ordersdb"
}
variable "db_username" {
  type    = string
  default = "dbadmin"
}
variable "db_instance_class" {
  type    = string
  default = "db.t3.micro"
}
variable "db_allocated_storage" {
  type    = number
  default = 20
}

variable "emr_release_label" {
  type    = string
  default = "emr-6.15.0"
}
variable "emr_master_instance_type" {
  type    = string
  default = "m4.large"
}
variable "emr_core_instance_type" {
  type    = string
  default = "m4.large"
}
variable "emr_core_instance_count" {
  type    = number
  default = 1
}

