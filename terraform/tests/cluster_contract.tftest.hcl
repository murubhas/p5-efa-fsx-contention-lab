mock_provider "aws" {}
mock_provider "aws-parallelcluster" {}

variables {
  region                   = "us-east-2"
  availability_zone        = "us-east-2b"
  vpc_id                   = "vpc-00000000000000000"
  private_subnet_id        = "subnet-00000000000000000"
  shared_security_group_id = "sg-00000000000000000"
  fsx_file_system_id       = "fs-00000000000000000"
  data_bucket_name         = "example-slurm-proof-data"
}

run "validated_two_node_p5_contract" {
  command = plan

  override_data {
    target = data.aws_subnet.compute
    values = {
      id                      = "subnet-00000000000000000"
      vpc_id                  = "vpc-00000000000000000"
      availability_zone       = "us-east-2b"
      map_public_ip_on_launch = false
    }
  }

  override_data {
    target = data.aws_security_group.shared
    values = {
      id     = "sg-00000000000000000"
      vpc_id = "vpc-00000000000000000"
    }
  }

  override_data {
    target = data.aws_s3_bucket.data
    values = {
      id     = "example-slurm-proof-data"
      bucket = "example-slurm-proof-data"
    }
  }

  override_data {
    target = data.aws_ec2_instance_type.head
    values = {
      supported_architectures = ["x86_64"]
    }
  }

  override_data {
    target = data.aws_ec2_instance_type.compute
    values = {
      supported_architectures = ["x86_64"]
    }
  }

  assert {
    condition     = output.cluster_template_contract.scheduler == "slurm"
    error_message = "Expected the rendered scheduler to remain Slurm."
  }

  assert {
    condition = alltrue([
      output.cluster_name == "p5-efa-fsx-contention",
      output.cluster_template_contract.head_instance_type == "m8i.xlarge",
      output.cluster_template_contract.iam_resource_prefix == "/parallelcluster/",
      output.cluster_template_contract.compute_instance_type == "p5.48xlarge",
      output.cluster_template_contract.capacity_type == "SPOT",
      output.cluster_template_contract.min_count == 0,
      output.cluster_template_contract.max_count == 2,
      output.cluster_template_contract.efa_enabled == true,
      output.cluster_template_contract.placement_group == false,
      output.cluster_template_contract.idle_scale_down == 10,
      output.cluster_template_contract.shared_mount == "/fsx",
    ])
    error_message = "The rendered topology no longer matches the validated two-node P5 contract."
  }
}

run "validated_efa_benchmark_fsx_contract" {
  command = plan

  variables {
    create_efa_benchmark_fsx = true
  }

  override_data {
    target = data.aws_subnet.compute
    values = {
      id                      = "subnet-00000000000000000"
      vpc_id                  = "vpc-00000000000000000"
      availability_zone       = "us-east-2b"
      map_public_ip_on_launch = false
    }
  }

  override_data {
    target = data.aws_security_group.shared
    values = {
      id     = "sg-00000000000000000"
      vpc_id = "vpc-00000000000000000"
    }
  }

  override_data {
    target = data.aws_s3_bucket.data
    values = {
      id     = "example-slurm-proof-data"
      bucket = "example-slurm-proof-data"
    }
  }

  override_data {
    target = data.aws_ec2_instance_type.head
    values = {
      supported_architectures = ["x86_64"]
    }
  }

  override_data {
    target = data.aws_ec2_instance_type.compute
    values = {
      supported_architectures = ["x86_64"]
    }
  }

  assert {
    condition = alltrue([
      length(aws_fsx_lustre_file_system.efa_benchmark) == 1,
      aws_fsx_lustre_file_system.efa_benchmark[0].deployment_type == "PERSISTENT_2",
      aws_fsx_lustre_file_system.efa_benchmark[0].storage_capacity == 19200,
      aws_fsx_lustre_file_system.efa_benchmark[0].per_unit_storage_throughput == 1000,
      aws_fsx_lustre_file_system.efa_benchmark[0].file_system_type_version == "2.15",
      aws_fsx_lustre_file_system.efa_benchmark[0].efa_enabled == true,
      aws_fsx_lustre_file_system.efa_benchmark[0].tags["auto-delete"] == "no",
    ])
    error_message = "The optional FSx resource drifted from the validated EFA/GDS benchmark contract."
  }
}

run "reject_public_subnet" {
  command = plan

  override_data {
    target = data.aws_subnet.compute
    values = {
      id                      = "subnet-00000000000000000"
      vpc_id                  = "vpc-00000000000000000"
      availability_zone       = "us-east-2b"
      map_public_ip_on_launch = true
    }
  }

  override_data {
    target = data.aws_security_group.shared
    values = {
      id     = "sg-00000000000000000"
      vpc_id = "vpc-00000000000000000"
    }
  }

  override_data {
    target = data.aws_s3_bucket.data
    values = {
      id     = "example-slurm-proof-data"
      bucket = "example-slurm-proof-data"
    }
  }

  override_data {
    target = data.aws_ec2_instance_type.head
    values = {
      supported_architectures = ["x86_64"]
    }
  }

  override_data {
    target = data.aws_ec2_instance_type.compute
    values = {
      supported_architectures = ["x86_64"]
    }
  }

  expect_failures = [check.subnet_is_private]
}

run "reject_graviton_head_for_p5_compute" {
  command = plan

  variables {
    head_instance_type = "m8g.xlarge"
  }

  override_data {
    target = data.aws_subnet.compute
    values = {
      id                      = "subnet-00000000000000000"
      vpc_id                  = "vpc-00000000000000000"
      availability_zone       = "us-east-2b"
      map_public_ip_on_launch = false
    }
  }

  override_data {
    target = data.aws_security_group.shared
    values = {
      id     = "sg-00000000000000000"
      vpc_id = "vpc-00000000000000000"
    }
  }

  override_data {
    target = data.aws_s3_bucket.data
    values = {
      id     = "example-slurm-proof-data"
      bucket = "example-slurm-proof-data"
    }
  }

  override_data {
    target = data.aws_ec2_instance_type.head
    values = {
      supported_architectures = ["arm64"]
    }
  }

  override_data {
    target = data.aws_ec2_instance_type.compute
    values = {
      supported_architectures = ["x86_64"]
    }
  }

  expect_failures = [check.head_and_compute_architectures_match]
}
