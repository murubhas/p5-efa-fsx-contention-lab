data "aws_subnet" "compute" {
  id = var.private_subnet_id
}

data "aws_security_group" "shared" {
  id = var.shared_security_group_id
}

data "aws_s3_bucket" "data" {
  bucket = var.data_bucket_name
}

data "aws_ec2_instance_type" "head" {
  instance_type = var.head_instance_type
}

data "aws_ec2_instance_type" "compute" {
  instance_type = "p5.48xlarge"
}

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

resource "aws_iam_policy" "parallelcluster_cloudwatch_alarm_tagging" {
  name        = "${var.api_stack_name}-CloudWatchAlarmTagging"
  description = "Allows the ParallelCluster API to tag the CloudWatch alarms it creates."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ManageParallelClusterAlarmTags"
        Effect = "Allow"
        Action = [
          "cloudwatch:ListTagsForResource",
          "cloudwatch:TagResource",
          "cloudwatch:UntagResource",
        ]
        Resource = "arn:${data.aws_partition.current.partition}:cloudwatch:${var.region}:${data.aws_caller_identity.current.account_id}:alarm:*"
      },
    ]
  })
}

check "subnet_belongs_to_expected_vpc" {
  assert {
    condition     = data.aws_subnet.compute.vpc_id == var.vpc_id
    error_message = "The selected private subnet does not belong to vpc_id."
  }
}

check "subnet_is_in_expected_az" {
  assert {
    condition     = data.aws_subnet.compute.availability_zone == var.availability_zone
    error_message = "The selected private subnet is not in availability_zone."
  }
}

check "security_group_belongs_to_expected_vpc" {
  assert {
    condition     = data.aws_security_group.shared.vpc_id == var.vpc_id
    error_message = "The selected security group does not belong to vpc_id."
  }
}

check "subnet_is_private" {
  assert {
    condition     = data.aws_subnet.compute.map_public_ip_on_launch == false
    error_message = "The Slurm proof expects a private subnet without automatic public IP assignment."
  }
}

check "head_and_compute_architectures_match" {
  assert {
    condition = length(setintersection(
      toset(data.aws_ec2_instance_type.head.supported_architectures),
      toset(data.aws_ec2_instance_type.compute.supported_architectures),
    )) > 0
    error_message = "ParallelCluster requires the head and Slurm compute instance types to use the same CPU architecture. P5 compute is x86_64, so Graviton head nodes are unsupported."
  }
}

locals {
  cluster_template_vars = {
    AWS_REGION         = var.region
    CLUSTER_NAME       = var.cluster_name
    HEAD_INSTANCE_TYPE = var.head_instance_type
    SUBNET_ID          = data.aws_subnet.compute.id
    SECURITY_GROUP_ID  = data.aws_security_group.shared.id
    FSX_ID             = var.fsx_file_system_id
  }

  rendered_cluster_configuration = templatefile(
    "${path.module}/../cluster.template.yaml",
    local.cluster_template_vars,
  )
  cluster_configuration = yamldecode(local.rendered_cluster_configuration)

  cluster_configs = {
    (var.cluster_name) = {
      region                 = var.region
      rollbackOnFailure      = true
      validationFailureLevel = "ERROR"
      configuration          = abspath("${path.module}/../cluster.template.yaml")
    }
  }
}

check "validated_two_node_p5_cluster_contract" {
  assert {
    condition = alltrue([
      local.cluster_configuration.Region == var.region,
      local.cluster_configuration.Image.Os == "ubuntu2204",
      local.cluster_configuration.Iam.ResourcePrefix == "/parallelcluster/",
      local.cluster_configuration.HeadNode.InstanceType == var.head_instance_type,
      local.cluster_configuration.Scheduling.Scheduler == "slurm",
      local.cluster_configuration.Scheduling.SlurmSettings.ScaledownIdletime == 10,
      local.cluster_configuration.Scheduling.SlurmSettings.QueueUpdateStrategy == "DRAIN",
      local.cluster_configuration.Scheduling.SlurmQueues[0].Name == "p5-spot",
      local.cluster_configuration.Scheduling.SlurmQueues[0].CapacityType == "SPOT",
      local.cluster_configuration.Scheduling.SlurmQueues[0].ComputeResources[0].InstanceType == "p5.48xlarge",
      local.cluster_configuration.Scheduling.SlurmQueues[0].ComputeResources[0].MinCount == 0,
      local.cluster_configuration.Scheduling.SlurmQueues[0].ComputeResources[0].MaxCount == 2,
      local.cluster_configuration.Scheduling.SlurmQueues[0].ComputeResources[0].Efa.Enabled == true,
      local.cluster_configuration.Scheduling.SlurmQueues[0].Networking.PlacementGroup.Enabled == false,
      local.cluster_configuration.SharedStorage[0].MountDir == "/fsx",
      local.cluster_configuration.SharedStorage[0].StorageType == "FsxLustre",
      local.cluster_configuration.SharedStorage[0].FsxLustreSettings.FileSystemId == var.fsx_file_system_id,
      local.cluster_configuration.Scheduling.SlurmQueues[0].CustomActions.OnNodeConfigured.Sequence[0].Script == "https://raw.githubusercontent.com/aws-samples/aws-parallelcluster-post-install-scripts/bb73e4f0a340663d2ac0dbbdf86b870e069331a5/docker/postinstall.sh",
      one([for tag in local.cluster_configuration.Tags : tag.Value if tag.Key == "Name"]) == var.cluster_name,
      one([for tag in local.cluster_configuration.Tags : tag.Value if tag.Key == "auto-delete"]) == "no",
    ])
    error_message = "The rendered cluster configuration drifted from the validated two-node P5 contract."
  }
}

module "parallelcluster" {
  source  = "aws-tf/parallelcluster/aws"
  version = "1.1.0"

  region                = var.region
  api_version           = var.parallelcluster_version
  api_stack_name        = var.api_stack_name
  deploy_pcluster_api   = true
  deploy_required_infra = false
  template_vars         = local.cluster_template_vars
  cluster_configs       = local.cluster_configs

  parameters = {
    EnableIamAdminAccess                      = "true"
    ParallelClusterFunctionAdditionalPolicies = aws_iam_policy.parallelcluster_cloudwatch_alarm_tagging.arn
  }
}

# Reading the bucket here makes a missing or mistyped shared-data dependency
# fail during planning without giving this state ownership of the bucket.
resource "terraform_data" "existing_data_contract" {
  input = {
    bucket_name = data.aws_s3_bucket.data.id
    fsx_id      = var.fsx_file_system_id
  }
}

# This filesystem is deliberately separate from the shared /fsx mount. It is
# opt-in, EFA-enabled, and protected from accidental Terraform destruction so
# the benchmark can compare /fsx with /fsx-efa without changing source data.
resource "aws_fsx_lustre_file_system" "efa_benchmark" {
  count = var.create_efa_benchmark_fsx ? 1 : 0

  deployment_type                 = "PERSISTENT_2"
  storage_type                    = "SSD"
  storage_capacity                = var.efa_benchmark_fsx_storage_capacity_gib
  per_unit_storage_throughput     = 1000
  file_system_type_version        = "2.15"
  subnet_ids                      = [data.aws_subnet.compute.id]
  security_group_ids              = [data.aws_security_group.shared.id]
  efa_enabled                     = true
  automatic_backup_retention_days = 0
  copy_tags_to_backups            = false
  data_compression_type           = "LZ4"

  metadata_configuration {
    mode = "AUTOMATIC"
  }

  tags = {
    Name        = "${var.cluster_name}-efa-benchmark"
    Purpose     = "p5-efa-fsx-contention"
    auto-delete = "no"
  }

  lifecycle {
    prevent_destroy = true
  }
}
