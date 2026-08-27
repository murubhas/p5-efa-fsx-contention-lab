terraform {
  required_version = ">= 1.7.0"

  backend "s3" {}

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0, < 7.0"
    }

    aws-parallelcluster = {
      source  = "aws-tf/aws-parallelcluster"
      version = "1.1.0"
    }
  }
}
