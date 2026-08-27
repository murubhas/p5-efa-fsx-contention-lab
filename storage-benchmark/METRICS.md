# Metrics and EFA traffic attribution

This reference explains what each measurement means, who emits it, and how the
experiment separates NCCL collective traffic from checkpoint-like GPUD traffic.

## The attribution boundary

EFA hardware counters are cumulative per NIC and port. They do not label bytes
by PID, container, Slurm step, NCCL communicator, cuFile handle, or filesystem
request. Therefore this experiment does **not** claim direct per-process EFA
accounting.

Instead, it uses controlled attribution:

1. run NCCL alone and capture `after - before` EFA deltas;
2. run GPUD checkpoint writers alone and capture the same deltas;
3. run both from one shared future UTC epoch;
4. correlate each counter signature with application completion records and
   identical benchmark windows.

In the validated run, NCCL-only was dominated by `rdma_write_bytes`, the GPUD
write arm was dominated by `rdma_read_resp_bytes`, and overlap contained both.
These are useful signatures for this tested topology, not universal protocol
rules.

![EFA measurement and attribution method](../assets/p5-efa-measurement-attribution.png)

## Measurement layers

| Layer | Source | What it answers | Authority |
|---|---|---|---|
| Workload | NCCL benchmark | Did all ranks complete, and at what payload/bus rate? | Primary performance metric for collectives |
| Workload | `gdsio` | Was the transfer GPUD, and at what GiB/s and latency? | Primary performance metric for checkpoint I/O |
| Runtime | NCCL logs | Was AWS Libfabric/GDRDMA selected, with no socket fallback? | Transport proof |
| Runtime | cuFile config and output | Was compatibility fallback disabled? | GDS path proof |
| Host | EFA hardware counters | Which NIC-level traffic and errors changed in the window? | Aggregate correlation evidence |
| Host | `/proc/driver/nvidia-fs/stats` | Did GDS complete without driver errors? | GDS health evidence |
| Host | `lnetctl` | Were EFA NIDs and FSx peers active, with healthy LNet stats? | Lustre/EFA path evidence |
| Service | FSx CloudWatch | What did the filesystem serve during the one-minute interval? | Filesystem-side throughput/utilization |
| GPU | DCGM exporter, optional | Were GPUs active, memory-resident, throttled, or errored? | Hardware context, not transport attribution |

Application metrics are the source of truth for performance. Runtime and host
metrics prove the intended path and absence of fallback. Service metrics show
filesystem pressure at coarser resolution.

## Metrics captured by the repository

### NCCL

`nccl_allreduce_benchmark.py` records:

- world size and rank correctness;
- tensor size per rank;
- iterations and iterations per second;
- algorithmic payload GB/s;
- estimated collective bus GB/s;
- the validated all-reduce value.

`run_nccl_benchmark_node.sh` additionally captures:

- exact UTC timestamps;
- EFA hardware counters before and after;
- AWS Libfabric and GDRDMA initialization records;
- any socket fallback record.

### GPUD checkpoint writer

`run_gdsio_checkpoint_write.sh` records:

- writer GPU, threads, duration, and file size per thread;
- transfer type, which must be `GPUD`;
- write GiB/s and mean kernel latency;
- compatibility-fallback policy, which must be false;
- `nvidia_fs`, LNet, and EFA counters before and after.

The reported `gdsio` latency covers the GDS operation observed by the tool. The
kernel `nvidia_fs` statistics measure submission-to-completion inside the GDS
path; they are not complete application checkpoint latency.

### POSIX controls

`run_fio_transport.sh` records write/read GB/s, IOPS, and mean latency against
both `/fsx` and `/fsx-efa`. The immediate read can benefit from server-side
cache and must not be described as durable-media throughput.

## Counter delta calculation

Hardware counters are cumulative. For every device and host:

```text
counter_delta = counter_after - counter_before
```

Then aggregate only matched, non-negative deltas:

```text
fleet_delta(counter) = sum(host_device_delta(counter))
```

Negative deltas usually indicate a device reset or counter wrap. The summarizer
reports them separately instead of silently adding them.

Run:

```bash
python3 summarize_efa_hardware_counters.py <result-directory>
```

## EFA counters worth monitoring

The AWS Labs EFA node-exporter collector exposes the host counters through the
standard node-exporter namespace. Useful series include:

| Metric | Interpretation |
|---|---|
| `node_amazonefa_rdma_write_bytes` | RDMA write bytes completed by EFA devices |
| `node_amazonefa_rdma_read_resp_bytes` | RDMA read-response bytes returned by EFA devices |
| `node_amazonefa_tx_bytes` | Aggregate transmit bytes |
| `node_amazonefa_rx_bytes` | Aggregate receive bytes |
| `node_amazonefa_retrans_bytes` | Bytes retransmitted by the transport |
| `node_amazonefa_retrans_pkts` | Retransmitted packets |
| `node_amazonefa_retrans_timeout_events` | Retransmission timeout events |
| `node_amazonefa_rdma_write_wr_err` | RDMA write work-request errors |
| `node_amazonefa_rdma_read_wr_err` | RDMA read work-request errors |
| `node_amazonefa_rx_drops` | Receive drops |
| `node_amazonefa_impaired_remote_conn_events` | Impaired remote-connection events |
| `node_amazonefa_unresponsive_remote_events` | Unresponsive remote-endpoint events |

Metric availability can vary by EFA driver and instance generation. Discover
the live series before building alerts.

### PromQL examples

Aggregate EFA RDMA-write throughput across the selected workers:

```promql
sum(rate(node_amazonefa_rdma_write_bytes{instance=~"$worker"}[1m]))
```

Convert to GiB/s:

```promql
sum(rate(node_amazonefa_rdma_write_bytes{instance=~"$worker"}[1m]))
/ 1024 / 1024 / 1024
```

Aggregate RDMA read-response throughput:

```promql
sum(rate(node_amazonefa_rdma_read_resp_bytes{instance=~"$worker"}[1m]))
/ 1024 / 1024 / 1024
```

Retransmitted-byte ratio:

```promql
sum(rate(node_amazonefa_retrans_bytes{instance=~"$worker"}[5m]))
/
clamp_min(sum(rate(node_amazonefa_tx_bytes{instance=~"$worker"}[5m])), 1)
```

Error and drop rate:

```promql
sum(rate(node_amazonefa_rdma_write_wr_err{instance=~"$worker"}[5m]))
+ sum(rate(node_amazonefa_rdma_read_wr_err{instance=~"$worker"}[5m]))
+ sum(rate(node_amazonefa_rx_drops{instance=~"$worker"}[5m]))
```

These are fleet-level series. Filtering to one process or container does not
turn NIC counters into process attribution.

## Prometheus on a Slurm fleet

The validated benchmark used before/after file snapshots, not Prometheus, so
that exact 90-second windows remained auditable even on elastic workers.

For continuous monitoring, run one node exporter plus the AWS Labs EFA
collector per worker and discover workers through one of these methods:

- Prometheus EC2 service discovery filtered by cluster/queue tags;
- file-based service discovery generated from Slurm node inventory;
- a site-managed node-exporter daemon installed by the ParallelCluster custom
  action.

Preserve `instance`, `device`, and `port` labels. Add Slurm job labels in a
separate metadata series or recording rule; do not imply that the underlying
EFA bytes were emitted per job.

For `nvidia_fs` and LNet, use a node-exporter textfile collector or an
OpenTelemetry host collector that snapshots:

- `/proc/driver/nvidia-fs/stats`;
- `lnetctl stats show`;
- `lnetctl net show` and peer health;
- a benchmark-window metadata gauge.

Resetting kernel statistics should be limited to isolated experiments. In a
shared production fleet, use monotonically increasing counters and `rate()`.

## FSx for Lustre CloudWatch metrics

FSx emits metrics in `AWS/FSx` with the filesystem ID dimension, generally at
one-minute resolution. Correlate these with the exact benchmark timestamps:

| Metric | Use |
|---|---|
| `DataWriteBytes` | Filesystem bytes written during the period |
| `DataReadBytes` | Filesystem bytes read during the period |
| `NetworkThroughputUtilization` | Network-side filesystem pressure |
| `NetworkSentBytes` / `NetworkReceivedBytes` | Filesystem network traffic |
| `FileServerDiskThroughputUtilization` | File-server disk pressure |
| OST disk utilization/throughput metrics | Storage-target pressure |

For byte counters returned as a period sum:

```text
filesystem_bytes_per_second = Sum(metric_bytes) / period_seconds
```

CloudWatch's one-minute buckets are too coarse to replace the application
metrics for a 90-second benchmark, but they are useful corroborating evidence.

## GPU context with DCGM

DCGM does not measure EFA or Lustre bytes. It explains whether a performance
change coincided with GPU behavior:

- `DCGM_FI_DEV_GPU_UTIL` - compute utilization;
- `DCGM_FI_DEV_FB_USED` and `DCGM_FI_DEV_FB_FREE` - HBM residency;
- `DCGM_FI_DEV_POWER_USAGE` - power draw;
- `DCGM_FI_DEV_GPU_TEMP` - thermals;
- `DCGM_FI_DEV_XID_ERRORS` - GPU/driver faults;
- NVLink throughput/error fields when supported by the deployed exporter.

Use DCGM as hardware context. It cannot tell whether a byte belonged to NCCL or
the GDS checkpoint writer.

## Contention formulas

For every metric:

```text
change_percent = (overlap - isolated) / isolated * 100
```

Interpretation:

- throughput: negative means regression;
- latency: positive means regression;
- error/drop/retransmit counters: any material increase requires inspection.

Repeat each arm and report median plus dispersion before setting an operational
threshold. One run is evidence, not an SLO.

## Primary references

- [AWS Labs EFA node exporter](https://github.com/awslabs/awsome-distributed-ai/tree/main/4.validation_and_observability/3.efa-node-exporter)
- [FSx for Lustre metrics](https://docs.aws.amazon.com/fsx/latest/LustreGuide/fs-metrics.html)
- [Monitoring FSx with CloudWatch](https://docs.aws.amazon.com/fsx/latest/LustreGuide/monitoring-cloudwatch.html)
- [NVIDIA GPUDirect Storage troubleshooting](https://docs.nvidia.com/gpudirect-storage/troubleshooting-guide/)

