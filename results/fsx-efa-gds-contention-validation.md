# FSx EFA, GDS, and NCCL contention validation

Date: 2026-08-27 UTC

## Result in one sentence

On this controlled two-node P5 run, synchronized GPUDirect Storage (GDS) checkpoint-like writes
reduced NCCL all-reduce payload throughput by 1.9%, while storage write
throughput fell 14.6% and mean write latency rose 17.0%.

This is one synthetic 90-second run per arm. It proves the tested data paths
and characterizes this topology; it is not a universal training, filesystem,
or AWS performance claim.

![NCCL and GDS contention architecture](../assets/p5-fsx-efa-gds-contention.png)

![EFA measurement and attribution method](../assets/p5-efa-measurement-attribution.png)

## Why this experiment exists

A distributed trainer can perform NCCL collectives while an asynchronous
checkpoint writer moves tensor data to shared storage. On P5, both paths can
use EFA:

- gradients: `PyTorch -> NCCL -> aws-ofi-nccl -> libfabric -> EFA/SRD`;
- checkpoint bytes: `GPU -> cuFile/nvidia-fs -> Lustre/kefalnd -> EFA/SRD -> FSx`.

The test asks a narrow question: when both paths run together on this exact
fleet and filesystem, which workload absorbs the contention?

## Controlled topology

| Property | Validated value |
|---|---|
| Scheduler | AWS ParallelCluster with Slurm |
| Compute | Two Spot `p5.48xlarge` workers |
| GPUs | 8 H100 80 GiB per worker; 16 total |
| EFA | 32 devices per worker |
| NCCL world | 16 ranks; 8 per worker |
| Filesystem | Dedicated EFA-enabled FSx for Lustre Persistent 2 SSD |
| FSx capacity | 19,200 GiB |
| FSx throughput setting | 1,000 MB/s/TiB |
| Mount | `/fsx-efa` |
| NCCL duration | 90 seconds per arm |
| Checkpoint duration | 90 seconds per arm |

The dedicated filesystem is separate from the existing `/fsx` filesystem, so
the experiment does not alter shared model or training data.

## Software contract

| Component | Observed value |
|---|---|
| OS / kernel | Ubuntu 22.04.5 / `6.8.0-1029-aws` |
| NVIDIA driver | 570.86.15 |
| CUDA / GDS | 12.8 / 1.13.0.11 |
| `nvidia_fs` | 2.24.2 |
| Lustre client | 2.15.6 |
| EFA driver | 2.15.0g |
| NCCL | 2.26.2 |
| `aws-ofi-nccl` | 1.14.2 |
| libfabric | 2.1 |

The GDS runner set `allow_compat_mode=false` and
`CUFILE_FORCE_COMPAT_MODE=false`. A result was accepted only when `gdsio`
reported `XferType: GPUD`.

## Baseline storage path

The POSIX control used one worker, eight `fio` jobs, 1 MiB blocks, direct I/O,
queue depth 32 per job, 16 GiB per job, and 90 seconds per phase.

| Filesystem path | Write | Read | Write mean latency | Read mean latency |
|---|---:|---:|---:|---:|
| Existing TCP FSx | 2.479 GB/s | 2.481 GB/s | 108.230 ms | 108.139 ms |
| Dedicated EFA FSx | 15.869 GB/s | 27.803 GB/s | 16.914 ms | 9.652 ms |

The immediate read phase may include FSx server-side cache effects. These
numbers are tool-observed client throughput, not durable-media guarantees.

An eight-GPU fail-closed GDS test on one worker reported:

| Operation | Aggregate throughput | Mean of GPU mean latency |
|---|---:|---:|
| Write | 20.128 GiB/s | 1.553 ms |
| Read | 19.643 GiB/s | 1.591 ms |

## Contention arms

### Arm A: NCCL only

- 16 ranks across two workers;
- 256 MiB float tensor per rank;
- repeated validated all-reduce for 90 seconds;
- 16/16 exact rank markers;
- AWS Libfabric and `GDRDMA` observed;
- zero `NET/Socket` fallback records.

### Arm B: checkpoint only

- one GDS writer on GPU 0 of each worker;
- four writer threads per worker;
- 16 GiB per thread;
- both writers begin from one shared UTC start epoch;
- fail closed if `XferType: GPUD` or EFA/Lustre peer discovery is absent.

This is a checkpoint-like data-plane workload. It does not include PyTorch
serialization, optimizer-state assembly, or Distributed Checkpoint metadata.

### Arm C: synchronized overlap

Arms A and B use the same parameters and shared start time. The only intended
change is concurrent execution.

## Results

| Metric | Isolated baseline | Synchronized overlap | Change |
|---|---:|---:|---:|
| NCCL algorithmic payload | 166.570 GB/s | 163.455 GB/s | -1.87% |
| NCCL estimated bus bandwidth | 312.319 GB/s | 306.478 GB/s | -1.87% |
| Checkpoint aggregate write | 6.625 GiB/s | 5.660 GiB/s | -14.57% |
| Checkpoint mean latency | 1.180 ms | 1.381 ms | +17.02% |

The percentage formula is:

```text
change % = (overlap - isolated) / isolated * 100
```

For latency, a positive result is a regression. For throughput, a negative
result is a regression.

## End-to-end proof gates

| Gate | Result |
|---|---|
| NCCL correctness | 16/16 ranks, validated tensor value 1.0 |
| NCCL transport | `NET/AWS Libfabric/.../GDRDMA` |
| NCCL fallback | Zero socket-fallback records |
| GDS mode | `GPUD`; compatibility fallback disabled |
| `nvidia_fs` | Zero read/write errors |
| EFA | Zero RDMA write errors and zero receive drops |
| Slurm placement | Exactly two workers retained in one exclusive allocation |

## What the hardware counters can and cannot say

The isolated arms produced distinct signatures:

- NCCL-only traffic was dominated by EFA `rdma_write_bytes`;
- checkpoint-only writes were dominated by `rdma_read_resp_bytes`;
- the overlap arm contained both signatures.

That supports attribution in this controlled experiment. EFA hardware counters
are still NIC-aggregate: they do not tag bytes by PID, container, NCCL
communicator, or cuFile handle. Application metrics remain the primary source
for performance, while EFA and `nvidia_fs` counters prove transport activity
and error-free execution.

## Interpretation

The storage path absorbed more contention than the collective path in this
run. That is useful operational evidence: asynchronous checkpointing can
reduce the amount of trainer blocking, but it does not make storage traffic
free. Rate limiting, staggering, or scheduling large checkpoint writes away
from the most communication-heavy phases may protect both checkpoint latency
and the training step time.

Before turning this into a production policy:

1. Repeat each arm several times and report confidence intervals.
2. Replace the synthetic writer with the application's real checkpoint stack.
3. Sweep checkpoint concurrency and file stripe settings.
4. Correlate step-time, NCCL, cuFile, Lustre, and EFA metrics on one timeline.
5. Validate again after changing AMI, kernel, driver, CUDA, GDS, or FSx type.

## Resource lifecycle

The two Spot P5 workers and the Slurm hold were released after the result was
verified. The elastic queue is designed to return to zero workers. After a
separate infrastructure review and explicit owner approval, the dedicated
EFA-enabled benchmark filesystem was deleted without a final backup. The
shared training filesystem was not modified. Terraform state was reconciled,
and the post-delete untargeted plan reported no remaining changes.

Machine-readable values are in
[`fsx-efa-gds-contention-summary.json`](fsx-efa-gds-contention-summary.json).
