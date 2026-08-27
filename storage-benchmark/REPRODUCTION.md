# Reproduce the FSx EFA, GDS, and NCCL contention experiment

This guide starts from a clean clone and reproduces the controlled experiment
reported in
[`../results/fsx-efa-gds-contention-validation.md`](../results/fsx-efa-gds-contention-validation.md).
It deliberately keeps infrastructure formation, host preparation, workload
execution, and evidence collection as separate gates.

The experiment has three 90-second arms on the same exclusive two-node P5
allocation:

1. NCCL all-reduce only;
2. checkpoint-like GPUD writes only;
3. NCCL and GPUD writes beginning at the same future UTC epoch.

The result is a topology-specific contention measurement, not a general AWS,
FSx, NCCL, or training-performance claim.

![EFA measurement and attribution method](../assets/p5-efa-measurement-attribution.png)

## 1. Prerequisites

Prepare these dependencies before creating anything:

- AWS credentials with reviewed permissions for ParallelCluster, EC2, IAM,
  CloudFormation, Systems Manager, and the optional FSx resource;
- Terraform 1.5.7 or later;
- Node.js 20 or later for repository checks and diagram generation;
- AWS ParallelCluster CLI 3.13.1;
- one existing private subnet in the selected P5-capacity Availability Zone;
- one security group that permits ParallelCluster, Lustre, and EFA peer
  communication within the cluster;
- one existing FSx for Lustre filesystem mounted by ParallelCluster at `/fsx`;
- one S3 bucket used by the existing platform data path;
- Spot quota and capacity for two `p5.48xlarge` workers;
- Systems Manager access to the private head and compute nodes.

The optional benchmark filesystem is FSx for Lustre Persistent 2 SSD with EFA
enabled. EFA cannot be added to an existing filesystem after creation, so this
repository creates a separate filesystem and mounts it at `/fsx-efa`.

## 2. Clone and validate locally

```bash
git clone https://github.com/murubhas/p5-efa-fsx-contention-lab.git
cd p5-efa-fsx-contention-lab

npm ci
terraform -chdir=terraform init -backend=false -input=false
npm run check
```

Do not place credentials, account IDs, private IPs, rendered cluster files,
Terraform state, or raw logs in the checkout. The publication check rejects
those artifacts.

## 3. Prepare the private Terraform inputs

Keep real values outside the repository:

```bash
cp terraform/terraform.tfvars.example /tmp/p5-efa-fsx.private.tfvars
${EDITOR:-vi} /tmp/p5-efa-fsx.private.tfvars
```

Set the existing VPC, private subnet, shared security group, existing FSx
filesystem, and S3 bucket. Enable the dedicated benchmark filesystem:

```hcl
create_efa_benchmark_fsx               = true
efa_benchmark_fsx_storage_capacity_gib = 19200
```

The benchmark filesystem is tagged `auto-delete=no` and protected by
`prevent_destroy`. Its deletion is intentionally a later, separately reviewed
decision.

## 4. Plan and form the cluster

Use a dedicated remote-state key. The Slurm state must not own the existing
VPC, subnet, security group, shared FSx filesystem, S3 bucket, or data
repository associations.

```bash
terraform -chdir=terraform init \
  -backend-config="bucket=<state-bucket>" \
  -backend-config="key=labs/p5-efa-fsx-contention/terraform.tfstate" \
  -backend-config="region=<region>"

terraform -chdir=terraform test
terraform -chdir=terraform plan \
  -var-file=/tmp/p5-efa-fsx.private.tfvars \
  -out=/tmp/p5-efa-fsx.tfplan
terraform -chdir=terraform show /tmp/p5-efa-fsx.tfplan
```

Stop if the plan replaces or destroys existing platform infrastructure. A
reviewed plan should create or update only the ParallelCluster-owned lifecycle
and, when enabled, the dedicated EFA benchmark filesystem.

```bash
terraform -chdir=terraform apply /tmp/p5-efa-fsx.tfplan
terraform -chdir=terraform output cluster_name
terraform -chdir=terraform output efa_benchmark_fsx
```

The cluster starts with a private x86 head and a Spot P5 queue configured with
`MinCount: 0` and `MaxCount: 2`. No P5 workers exist until Slurm asks for them.

## 5. Stage the benchmark kit on shared FSx

Connect to the private head through Systems Manager. Clone or copy the
repository to the head, then stage only the runner files into the shared path:

```bash
sudo install -d -o ubuntu -g ubuntu /fsx/p5-efa-fsx-contention-lab/results
sudo cp storage-benchmark/* /fsx/p5-efa-fsx-contention-lab/
sudo chown -R ubuntu:ubuntu /fsx/p5-efa-fsx-contention-lab
sudo chmod 0755 /fsx/p5-efa-fsx-contention-lab/*.sh
```

The NCCL launcher expects the Python benchmark and node launcher directly
under `/fsx/p5-efa-fsx-contention-lab`, not one directory deeper.

## 6. Secure the two workers with an exclusive hold

Create a temporary hold manifest on the head:

```bash
cat >/tmp/p5-efa-gds-hold.sbatch <<'EOF'
#!/usr/bin/env bash
#SBATCH --job-name=p5-efa-gds-hold
#SBATCH --partition=p5-spot
#SBATCH --nodes=2
#SBATCH --ntasks=2
#SBATCH --ntasks-per-node=1
#SBATCH --gres=gpu:8
#SBATCH --exclusive
#SBATCH --time=08:00:00
#SBATCH --output=/fsx/p5-efa-fsx-contention-lab/results/hold-%j.out
#SBATCH --error=/fsx/p5-efa-fsx-contention-lab/results/hold-%j.err

sleep 28800
EOF

JOB_ID=$(/opt/slurm/bin/sbatch --parsable /tmp/p5-efa-gds-hold.sbatch)
echo "hold job: ${JOB_ID}"
/opt/slurm/bin/squeue -j "${JOB_ID}"
```

Wait until the job is `RUNNING` with exactly two nodes. Slurm's all-or-nothing
allocation keeps the benchmark from starting on one node.

```bash
/opt/slurm/bin/scontrol show job "${JOB_ID}"
/opt/slurm/bin/scontrol show hostnames \
  "$(/opt/slurm/bin/squeue -h -j "${JOB_ID}" -o '%N')"
```

Do not perform long image pulls or host setup on unallocated Spot nodes. The
exclusive hold prevents the elastic queue from treating the workers as idle.

Record the two worker instance IDs and worker A's reachable private address for
the sideband launcher. Derive them from the Slurm node addresses and an EC2
read-only lookup; do not publish them:

```bash
export WORKER_A_ID=<worker-a-instance-id>
export WORKER_B_ID=<worker-b-instance-id>
export MASTER_ADDR=<worker-a-private-address>
```

## 7. Prepare each worker

Use Systems Manager to open a root-capable session to each worker. This was the
validated least-privilege path because the Slurm user was not added to the
Docker group and did not receive passwordless root.

On both workers, from the staged shared directory:

```bash
cd /fsx/p5-efa-fsx-contention-lab
sudo ./collect_worker_inventory.sh
sudo ./configure_efa_preserve_tcp.sh gds
sudo ./install_nvidia_fs.sh
```

Read the benchmark filesystem connection contract from the Terraform output,
then mount it on both workers:

```bash
sudo mkdir -p /fsx-efa
sudo mount -t lustre \
  <benchmark-fsx-dns-name>@tcp:/<benchmark-fsx-mount-name> \
  /fsx-efa
```

The `@tcp` text in the Lustre mount source is expected even for an EFA-enabled
FSx filesystem. The EFA client setup adds EFA LNet NIDs, peer discovery, and
the routing policy used for the bulk path. Do not classify the active data path
from the `findmnt` source string alone.

Verify every gate on both workers:

```bash
mountpoint /fsx
mountpoint /fsx-efa
nvidia-smi --query-gpu=index,name,memory.total --format=csv,noheader
find /dev/infiniband -maxdepth 1 -name 'uverbs*' | wc -l
sudo lnetctl net show --net efa
sudo lnetctl peer show -v 4
cat /proc/driver/nvidia-fs/version
sudo /usr/local/cuda/gds/tools/gdscheck -p
```

Expected per worker: 8 H100 GPUs, 32 EFA devices, local `@efa` NIDs, discovered
filesystem peers, and a loaded `nvidia_fs` module.

## 8. Smoke the storage paths

Run each command with a unique label. A completed label is immutable and the
runners refuse to overwrite it.

On one worker:

```bash
cd /fsx/p5-efa-fsx-contention-lab
sudo ./run_fio_transport.sh tcp-control-<run> /fsx 90 8 16G
sudo ./run_fio_transport.sh efa-posix-<run> /fsx-efa 90 8 16G
sudo ./run_gdsio_transport.sh gds-eight-gpu-<run> /fsx-efa 90 4 16G
```

Accept the GDS smoke only if every GPU reports `XferType: GPUD`, the generated
cuFile configuration disables compatibility fallback, and `nvidia_fs` reports
zero errors.

## 9. Run the three contention arms

Use identical durations and payloads in all arms. Allow the system to return to
idle between arms and capture the exact UTC windows.

### Arm A: NCCL only

When the approved Slurm container policy permits the allocated user to start
the pinned runtime:

```bash
sudo -u ubuntu -- env \
  START_AT_EPOCH="$(($(date +%s) + 45))" \
  /fsx/p5-efa-fsx-contention-lab/run_nccl_slurm_step.sh \
  "${JOB_ID}" nccl-only-<run> 90 256
```

The runner forms 16 ranks, verifies the all-reduce value, captures EFA counters
before and after, and records the runtime logs. Reject the arm if any rank is
missing, if AWS Libfabric/GDRDMA is absent, or if `NET/Socket` appears.

The validated environment instead used the repository's Systems Manager pair
launcher, which executes the root-only container command on the two workers
while Slurm continues to retain the allocation:

```bash
cd storage-benchmark
export AWS_REGION=<region>
START_AT_EPOCH="$(($(date +%s) + 60))"
./run_ssm_pair.sh nccl \
  "${WORKER_A_ID}" "${WORKER_B_ID}" "${MASTER_ADDR}" \
  nccl-only-<run> 90 256 "${START_AT_EPOCH}"
```

### Arm B: checkpoint only

Choose one shared future epoch at least 60 seconds away and invoke both
allocated workers through Systems Manager:

```bash
cd storage-benchmark
export AWS_REGION=<region>
START_AT_EPOCH="$(($(date +%s) + 60))"
./run_ssm_pair.sh checkpoint \
  "${WORKER_A_ID}" "${WORKER_B_ID}" checkpoint-only-<run> \
  /fsx-efa 90 0 4 16G "${START_AT_EPOCH}"
```

Each worker uses GPU 0 and four threads. The result represents a checkpoint
data plane; it does not include PyTorch serialization, optimizer-state
assembly, or Distributed Checkpoint metadata.

### Arm C: synchronized overlap

Choose a new future epoch. Dispatch the checkpoint command to both workers
first, then dispatch NCCL with the same `START_AT_EPOCH`:

```bash
cd storage-benchmark
export AWS_REGION=<region>
START_AT_EPOCH="$(($(date +%s) + 90))"

./run_ssm_pair.sh checkpoint \
  "${WORKER_A_ID}" "${WORKER_B_ID}" overlap-<run> \
  /fsx-efa 90 0 4 16G "${START_AT_EPOCH}" &
CHECKPOINT_LAUNCHER_PID=$!

./run_ssm_pair.sh nccl \
  "${WORKER_A_ID}" "${WORKER_B_ID}" "${MASTER_ADDR}" \
  overlap-<run> 90 256 "${START_AT_EPOCH}"

wait "${CHECKPOINT_LAUNCHER_PID}"
```

The future timestamp is the synchronization contract. Starting commands one
after another without that contract creates an unknown overlap window.

If the site permits neither Slurm-native containers nor a narrowly scoped
helper, retain placement with Slurm and use Systems Manager for the root-only
container and GDS commands. Do not grant persistent Docker-group membership
merely for this test.

## 10. Summarize and verify

Each arm writes application output, timestamps, before/after EFA counters, and
a `complete` marker under:

```text
/fsx/p5-efa-fsx-contention-lab/results/<label>/
```

Summarize any directory that directly contains matched EFA counter files:

```bash
python3 /fsx/p5-efa-fsx-contention-lab/summarize_efa_hardware_counters.py \
  /fsx/p5-efa-fsx-contention-lab/results/<label>
```

For checkpoint labels, inspect the per-worker `gds-<host>` directories as well.
Keep the following evidence together for each arm:

- start and end timestamps;
- NCCL algorithmic payload, estimated bus bandwidth, iterations, and rank
  correctness;
- GPUD throughput, latency, transfer type, and fallback setting;
- EFA counter deltas per worker and aggregate;
- `nvidia_fs` before/after statistics;
- LNet network, peer, and error statistics;
- FSx CloudWatch metrics for the exact window.

The formulas and optional Prometheus queries are in
[`METRICS.md`](METRICS.md).

## 11. Acceptance gates

Do not report a performance delta unless all gates pass:

| Gate | Required result |
|---|---|
| Placement | Same two exclusively allocated workers for every arm |
| Timing | Same duration and synchronized start for overlap |
| NCCL correctness | 16/16 rank markers and validated tensor value |
| NCCL transport | AWS Libfabric and GDRDMA present |
| NCCL fallback | Zero `NET/Socket` records |
| GDS transfer | `XferType: GPUD` on both workers |
| GDS fallback | Compatibility mode disabled |
| Host errors | Zero `nvidia_fs` errors |
| EFA errors | Zero RDMA write errors and receive drops |
| Evidence | Before/after timestamps and counters present |

Calculate each contention delta as:

```text
change_percent = (overlap_value - isolated_value) / isolated_value * 100
```

For throughput, negative is regression. For latency, positive is regression.

## 12. Retain before cleanup

Preserve the raw result tree, machine-readable summaries, reviewed report, and
Terraform plan before releasing anything. Cancellation of the hold, P5
scale-down, and benchmark-filesystem deletion are separate owner-approved
actions. Do not combine them with result collection.

## Primary references

- [Configure EFA-enabled FSx clients](https://docs.aws.amazon.com/fsx/latest/LustreGuide/configure-efa-clients.html)
- [EFA-enabled FSx for Lustre](https://docs.aws.amazon.com/fsx/latest/LustreGuide/efa-file-systems.html)
- [Mount FSx for Lustre](https://docs.aws.amazon.com/fsx/latest/LustreGuide/mounting-ec2-instance.html)
- [NVIDIA GPUDirect Storage troubleshooting](https://docs.nvidia.com/gpudirect-storage/troubleshooting-guide/)
