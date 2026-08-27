# Terraform design for the P5 EFA and FSx contention lab

This directory shows how to manage the ParallelCluster control plane and Slurm
cluster with Terraform while preserving the ownership of existing platform
infrastructure.

## Ownership model

Terraform in this directory owns:

- the ParallelCluster API stack;
- the ParallelCluster cluster definition;
- the Slurm head node, scheduler configuration, IAM roles, logging, and elastic
  P5 queue created by ParallelCluster;
- when explicitly enabled, one dedicated EFA/GDS benchmark filesystem protected
  by `prevent_destroy`.

It reads or receives as inputs, but does not own:

- the VPC and private subnet;
- the shared security group;
- the external FSx for Lustre file system;
- the S3 bucket and FSx data repository associations.

`deploy_required_infra = false` is the key safety boundary. The external FSx
file system is attached by `FileSystemId`, so deleting the Slurm cluster does
not delete the shared training data.

The optional benchmark filesystem is a different ownership class. Setting
`create_efa_benchmark_fsx = true` creates a dedicated EFA-enabled Persistent 2
filesystem in this state. It is mounted separately at `/fsx-efa` by the
benchmark procedure, tagged `auto-delete=no`, and protected from accidental
Terraform destruction.

## Validated ownership state

Do not mix Terraform ownership with direct `pcluster create-cluster` or
`pcluster delete-cluster` operations against the same cluster. Once this module
owns a cluster, use reviewed Terraform plans for its control-plane lifecycle.

The default head is `m8i.xlarge`. P5 compute is `x86_64`, and ParallelCluster
requires head and compute nodes to share a CPU architecture. A root check fails
before deployment if an ARM/Graviton head such as `m7g` or `m8g` is selected.

## Remote state

Use a separate state key for the Slurm cluster. Existing platform resources can
be supplied from reviewed remote-state outputs or explicit variables. Do not
copy those resources into this state.

```bash
terraform init \
  -backend-config="bucket=REPLACE_ME" \
  -backend-config="key=labs/p5-efa-fsx-contention/terraform.tfstate" \
  -backend-config="region=us-east-2"

terraform fmt -check -recursive
terraform validate
terraform test
terraform plan -out=p5-efa-fsx.tfplan
```

Review the saved plan before applying. A safe plan may change the
ParallelCluster API or cluster lifecycle, but it must not replace the existing
VPC, subnet, FSx file system, S3 bucket, or data repository associations.

To include the dedicated storage benchmark in a reviewed plan:

```hcl
create_efa_benchmark_fsx               = true
efa_benchmark_fsx_storage_capacity_gib = 19200
```

At 1,000 MB/s/TiB, EFA-enabled capacity is constrained to supported multiples
of 4,800 GiB. The module validates that contract. Because `prevent_destroy` is
enabled, cleanup is intentionally a separate decision: preserve results,
obtain approval, remove the protection in a reviewed change, and only then
plan deletion. Never work around the guard with an unreviewed state edit.

The official module requires Terraform 1.5.7 or later and the
`aws-tf/aws-parallelcluster` provider. The module and provider are pinned at
`1.1.0`; the ParallelCluster API is pinned separately to the runtime version
validated by this proof.

## Automated contract tests

`tests/cluster_contract.tftest.hcl` uses mocked AWS and ParallelCluster
providers. It verifies that the rendered configuration still describes the
validated two-node P5 topology, rejects a subnet configured to assign public
IP addresses, and rejects a Graviton head paired with P5 compute.

These tests create no AWS resources. A real `terraform plan` is still required
against the target VPC, subnet, security group, FSx filesystem, and S3 bucket
before any deployment.

The ParallelCluster API role uses the `/parallelcluster/` resource prefix. A
small additional policy grants only CloudWatch alarm tag operations required by
cluster creation. Both constraints are encoded in Terraform so a clean rebuild
does not depend on console patches.

## Production IAM boundary

This proof follows the official module example and enables IAM administration
for the ParallelCluster API so it can create cluster roles automatically.
Review that setting before production use. Environments with stricter controls
should supply pre-created least-privilege roles and policies instead.
