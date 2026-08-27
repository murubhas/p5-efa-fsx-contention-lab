provider "aws" {
  region  = var.region
  profile = var.profile
}

provider "aws-parallelcluster" {
  region   = var.region
  profile  = var.profile
  endpoint = module.parallelcluster.pcluster_api_stack_outputs.ParallelClusterApiInvokeUrl
  role_arn = module.parallelcluster.pcluster_api_stack_outputs.ParallelClusterApiUserRole
}
