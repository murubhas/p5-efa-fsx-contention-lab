"""Duration-bounded NCCL all-reduce benchmark for the two-node P5 lab."""

from __future__ import annotations

import json
import os
import socket
import time
from datetime import timedelta

import torch
import torch.distributed as dist


def main() -> None:
    local_rank = int(os.environ["LOCAL_RANK"])
    duration_seconds = float(os.environ.get("BENCHMARK_SECONDS", "90"))
    tensor_mib = int(os.environ.get("NCCL_TENSOR_MIB", "256"))
    warmup_iterations = int(os.environ.get("NCCL_WARMUP_ITERATIONS", "10"))
    check_interval = int(os.environ.get("NCCL_TIME_CHECK_INTERVAL", "5"))
    start_at_epoch = float(os.environ.get("START_AT_EPOCH", "0"))

    torch.cuda.set_device(local_rank)
    dist.init_process_group(backend="nccl", timeout=timedelta(seconds=600))

    rank = dist.get_rank()
    world_size = dist.get_world_size()
    device = torch.device("cuda", local_rank)
    element_count = tensor_mib * 1024 * 1024 // torch.tensor([], dtype=torch.float32).element_size()
    payload = torch.ones(element_count, dtype=torch.float32, device=device)
    stop = torch.zeros(1, dtype=torch.int32, device=device)

    for _ in range(warmup_iterations):
        dist.all_reduce(payload, op=dist.ReduceOp.SUM)
        payload.mul_(1.0 / world_size)

    torch.cuda.synchronize()
    if rank == 0 and start_at_epoch:
        time.sleep(max(0.0, start_at_epoch - time.time()))
    dist.barrier()
    started = time.perf_counter()
    iterations = 0

    while True:
        for _ in range(check_interval):
            dist.all_reduce(payload, op=dist.ReduceOp.SUM)
            payload.mul_(1.0 / world_size)
            iterations += 1

        if rank == 0:
            stop.fill_(int(time.perf_counter() - started >= duration_seconds))
        dist.broadcast(stop, src=0)
        if stop.item():
            break

    torch.cuda.synchronize()
    dist.barrier()
    elapsed = time.perf_counter() - started

    first_value = payload[0].item()
    if abs(first_value - 1.0) > 1e-3:
        raise RuntimeError(f"All-reduce validation failed: first_value={first_value}")

    tensor_bytes = payload.numel() * payload.element_size()
    algorithmic_gbps = tensor_bytes * iterations / elapsed / 1e9
    bus_gbps = algorithmic_gbps * (2 * (world_size - 1) / world_size)
    result = {
        "host": socket.gethostname(),
        "rank": rank,
        "local_rank": local_rank,
        "world_size": world_size,
        "tensor_mib": tensor_mib,
        "iterations": iterations,
        "elapsed_seconds": elapsed,
        "iterations_per_second": iterations / elapsed,
        "algorithmic_payload_GBps": algorithmic_gbps,
        "estimated_bus_GBps": bus_gbps,
        "validated_value": first_value,
    }
    print("NCCL_RANK_RESULT " + json.dumps(result, sort_keys=True), flush=True)

    if rank == 0:
        print("NCCL_BENCHMARK_COMPLETE " + json.dumps(result, sort_keys=True), flush=True)

    dist.destroy_process_group()


if __name__ == "__main__":
    main()
