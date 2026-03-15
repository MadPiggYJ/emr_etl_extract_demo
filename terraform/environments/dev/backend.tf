terraform {
  backend "s3" {
    bucket         = "tf-lock-s3-20260218"
    key            = "week5/day2/terraform-emr-etl.tfstate"
    region         = "ap-southeast-2"
    dynamodb_table = "terraform-lock-table"
    encrypt        = true
  }
}