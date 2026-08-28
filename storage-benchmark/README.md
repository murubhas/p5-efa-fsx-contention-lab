# FSx EFA, GDS, and NCCL benchmark kit

This directory reproduces the storage and communication experiment documented
in [`../results/fsx-efa-gds-contention-validation.md`](../results/fsx-efa-gds-contention-validation.md).

Start with the [clean-clone reproduction guide](REPRODUCTION.md). Use
[METRICS.md](METRICS.md) when instrumenting Prometheus, CloudWatch, DCGM, EFA,
LNet, or `nvidia_fs`, or when explaining the attribution boundary.

For an audience-facing walkthrough, open the self-contained
[animated EFA and FSx contention explainer](../docs/p5-efa-fsx-contention-animation.html).

## What it proves

The kit contains independent and overlapping test arms for:

1. POSIX `fio` over an existing TCP FSx mount and an EFA-enabled FSx mount;
2. fail-closed GDS reads and writes with NVIDIA `gdsio`;
3. a 16-rank NCCL all-reduce over AWS Libfabric and EFA;
4. synchronized NCCL and checkpoint-like GDS writers;
5. before/after EFA hardware-counter collection.

It intentionally separates application metrics from transport proof. NCCL and
`gdsio` report performance; NCCL logs, `nvidia_fs`, LNet, and EFA counters prove
which data paths were active.

## Prerequisites

- two `p5.48xlarge` workers in one exclusive Slurm allocation;
- 8 H100 GPUs and 32 EFA devices visible on each worker;
- one EFA-enabled FSx for Lustre filesystem mounted at `/fsx-efa`;
- Lustre 2.15, EFA LNet peers, and the `kefalnd` module;
- CUDA GDS tools and `nvidia_fs` 2.24.2 or a validated compatible release;
- the pinned AWS PyTorch training image used by the Slurm proof;
- root only for host-level GDS, LNet, and EFA diagnostics.

Keep the original `/fsx` TCP mount active while adding the EFA network and
`/fsx-efa`. `configure_efa_preserve_tcp.sh` fails if the expected TCP LNet is
absent and refuses to stack a second EFA LNet configuration.

## Files

| File | Purpose |
|---|---|
| `REPRODUCTION.md` | Complete clone-to-run procedure, safety gates, and retention boundary |
| `METRICS.md` | Metric ownership, PromQL, formulas, and EFA attribution limits |
| `collect_worker_inventory.sh` | Capture OS, GPU, EFA, Lustre, GDS, and topology inventory |
| `configure_efa_preserve_tcp.sh` | Add regular or GDS-optimized EFA LNet without removing TCP |
| `install_nvidia_fs.sh` | Pin, build, and load the validated `nvidia_fs` module |
| `run_fio_transport.sh` | Matched POSIX write/read test against a selected mount |
| `run_gdsio_transport.sh` | All-GPU, fail-closed GDS write/read test |
| `run_gdsio_checkpoint_write.sh` | One checkpoint-like GDS writer per node |
| `nccl_allreduce_benchmark.py` | Duration-bounded, correctness-checked NCCL workload |
| `run_nccl_benchmark_node.sh` | Start eight NCCL ranks on one worker |
| `run_nccl_slurm_step.sh` | Slurm-native two-node launcher when permitted |
| `run_ssm_pair.sh` | Least-privilege two-worker launcher for NCCL or GDS through Systems Manager |
| `summarize_efa_hardware_counters.py` | Aggregate EFA counter deltas across workers |

## Safe sequence

1. Submit an exclusive two-node hold and wait for both Spot workers.
2. Capture inventory before modifying LNet or loading `nvidia_fs`.
3. Configure EFA LNet in `gds` mode while preserving the TCP mount.
4. Mount the EFA-enabled filesystem at `/fsx-efa`.
5. Run a one-GPU GDS smoke and reject compatibility fallback.
6. Run matched TCP and EFA POSIX controls.
7. Run the eight-GPU GDS test.
8. Run NCCL-only and checkpoint-only baselines.
9. Run synchronized overlap with one shared future epoch.
10. Summarize application metrics and hardware-counter deltas.
11. Retain or release resources only under the experiment owner's direction.

The exact commands, Slurm hold manifest, Systems Manager sideband path, and
acceptance matrix are in [`REPRODUCTION.md`](REPRODUCTION.md).

Every runner refuses to overwrite a result directory containing a `complete`
marker. Use a unique label for every arm.

## Representative commands

On one worker, after the EFA filesystem is mounted:

```bash
sudo ./configure_efa_preserve_tcp.sh gds
sudo ./install_nvidia_fs.sh
sudo ./run_fio_transport.sh tcp-control /fsx 90 8 16G
sudo ./run_fio_transport.sh efa-posix /fsx-efa 90 8 16G
sudo ./run_gdsio_transport.sh gds-eight-gpu /fsx-efa 90 4 16G
```

For one checkpoint-like writer per worker, calculate one future UTC epoch and
use the same value on both workers:

```bash
export START_AT_EPOCH=<shared-future-epoch>
sudo ./run_gdsio_checkpoint_write.sh checkpoint-only /fsx-efa 90 0 4 16G
```

Run the NCCL benchmark through an existing Slurm allocation when the cluster's
container policy permits the Slurm user to start the pinned runtime:

```bash
./run_nccl_slurm_step.sh <job-id> nccl-only 90 256
```

## Least-privilege note

The validated cluster did not grant the Slurm user Docker-group membership or
passwordless root. Those permissions would provide durable root-equivalent
access and were intentionally not added. The live diagnostics run therefore
kept the nodes exclusively allocated by Slurm while Systems Manager invoked
the root-only host and Docker probes on those same workers.

For a production-quality Slurm-native path, prefer an approved HPC container
runtime such as Apptainer/Enroot or a narrowly scoped privileged helper. Do not
add users to the Docker group merely to make this benchmark convenient.

## Interpreting counters

Use `summarize_efa_hardware_counters.py` on a result directory containing
matched `before` and `after` files:

```bash
python3 summarize_efa_hardware_counters.py <result-directory>
```

The counters are aggregated per NIC and host. Isolated baselines can reveal
useful signatures, but the counters do not provide per-process attribution.
Correlate them with NCCL completion records, `gdsio` output, and benchmark start
and end timestamps. See [`METRICS.md`](METRICS.md) for the complete measurement
model and optional continuous-monitoring queries.
