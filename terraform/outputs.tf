output "cluster_name" {
  value = var.cluster_name
}

output "cluster_template_contract" {
  description = "Non-sensitive summary of the rendered two-node P5 cluster contract."
  value = {
    image_os              = local.cluster_configuration.Image.Os
    iam_resource_prefix   = local.cluster_configuration.Iam.ResourcePrefix
    scheduler             = local.cluster_configuration.Scheduling.Scheduler
    head_instance_type    = local.cluster_configuration.HeadNode.InstanceType
    head_architectures    = data.aws_ec2_instance_type.head.supported_architectures
    queue_name            = local.cluster_configuration.Scheduling.SlurmQueues[0].Name
    capacity_type         = local.cluster_configuration.Scheduling.SlurmQueues[0].CapacityType
    compute_instance_type = local.cluster_configuration.Scheduling.SlurmQueues[0].ComputeResources[0].InstanceType
    compute_architectures = data.aws_ec2_instance_type.compute.supported_architectures
    min_count             = local.cluster_configuration.Scheduling.SlurmQueues[0].ComputeResources[0].MinCount
    max_count             = local.cluster_configuration.Scheduling.SlurmQueues[0].ComputeResources[0].MaxCount
    efa_enabled           = local.cluster_configuration.Scheduling.SlurmQueues[0].ComputeResources[0].Efa.Enabled
    placement_group       = local.cluster_configuration.Scheduling.SlurmQueues[0].Networking.PlacementGroup.Enabled
    idle_scale_down       = local.cluster_configuration.Scheduling.SlurmSettings.ScaledownIdletime
    shared_mount          = local.cluster_configuration.SharedStorage[0].MountDir
    configuration_sha256  = sha256(local.rendered_cluster_configuration)
  }
}

output "parallelcluster_api_stack_name" {
  value = module.parallelcluster.pcluster_api_stack_name
}

output "parallelcluster_clusters" {
  value = module.parallelcluster.clusters
}

output "reused_infrastructure" {
  value = {
    vpc_id            = var.vpc_id
    private_subnet_id = data.aws_subnet.compute.id
    availability_zone = data.aws_subnet.compute.availability_zone
    security_group_id = data.aws_security_group.shared.id
    fsx_id            = var.fsx_file_system_id
    data_bucket       = data.aws_s3_bucket.data.id
  }
}

output "efa_benchmark_fsx" {
  description = "Connection contract for the optional EFA-enabled benchmark filesystem."
  value = var.create_efa_benchmark_fsx ? {
    file_system_id  = aws_fsx_lustre_file_system.efa_benchmark[0].id
    dns_name        = aws_fsx_lustre_file_system.efa_benchmark[0].dns_name
    mount_name      = aws_fsx_lustre_file_system.efa_benchmark[0].mount_name
    mount_directory = "/fsx-efa"
    efa_enabled     = aws_fsx_lustre_file_system.efa_benchmark[0].efa_enabled
    storage_gib     = aws_fsx_lustre_file_system.efa_benchmark[0].storage_capacity
    throughput_tier = aws_fsx_lustre_file_system.efa_benchmark[0].per_unit_storage_throughput
  } : null
}
