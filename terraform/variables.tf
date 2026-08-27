variable "region" {
  description = "AWS Region containing the existing infrastructure."
  type        = string
}

variable "profile" {
  description = "Optional local AWS CLI profile. Omit in CI and use role credentials."
  type        = string
  default     = null
}

variable "cluster_name" {
  description = "Name of the ParallelCluster owned by this dedicated Terraform state."
  type        = string
  default     = "p5-efa-fsx-contention"
}

variable "head_instance_type" {
  description = "x86_64 EC2 instance type for the ParallelCluster head node. Its architecture must match the P5 compute fleet."
  type        = string
  default     = "m8i.xlarge"
}

variable "parallelcluster_version" {
  description = "ParallelCluster API version. Keep this aligned with the validated cluster runtime."
  type        = string
  default     = "3.13.1"
}

variable "api_stack_name" {
  description = "CloudFormation stack name for the ParallelCluster API used by the Terraform provider."
  type        = string
  default     = "ParallelClusterAPI-3131"
}

variable "vpc_id" {
  description = "Existing VPC ID. Terraform reads it for validation but does not own it."
  type        = string
}

variable "private_subnet_id" {
  description = "Existing private subnet used by the head and P5 compute nodes."
  type        = string
}

variable "availability_zone" {
  description = "Expected Availability Zone for the private subnet and P5 capacity."
  type        = string
}

variable "shared_security_group_id" {
  description = "Existing security group permitting Slurm, FSx for Lustre, and EFA peer traffic."
  type        = string
}

variable "fsx_file_system_id" {
  description = "Existing external FSx for Lustre file system mounted at /fsx."
  type        = string
}

variable "data_bucket_name" {
  description = "Existing S3 bucket associated with FSx through data repository associations."
  type        = string
}

variable "create_efa_benchmark_fsx" {
  description = "Create a dedicated EFA-enabled FSx for Lustre filesystem for the storage benchmark."
  type        = bool
  default     = false
}

variable "efa_benchmark_fsx_storage_capacity_gib" {
  description = "Capacity of the EFA-enabled Persistent_2 filesystem. At 1000 MB/s/TiB, EFA-enabled capacity must be a multiple of 4800 GiB."
  type        = number
  default     = 19200

  validation {
    condition = (
      var.efa_benchmark_fsx_storage_capacity_gib >= 4800 &&
      var.efa_benchmark_fsx_storage_capacity_gib % 4800 == 0
    )
    error_message = "efa_benchmark_fsx_storage_capacity_gib must be at least 4800 GiB and a multiple of 4800 GiB."
  }
}
