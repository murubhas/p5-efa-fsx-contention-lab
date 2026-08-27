#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  run_ssm_pair.sh nccl WORKER_A_ID WORKER_B_ID MASTER_ADDR LABEL [SECONDS] [TENSOR_MIB] [START_EPOCH]
  run_ssm_pair.sh checkpoint WORKER_A_ID WORKER_B_ID LABEL [MOUNT] [SECONDS] [GPU] [THREADS] [SIZE] [START_EPOCH]

AWS_REGION must be set. AWS_PROFILE is honored by the AWS CLI when present.
The two workers must already be retained by one exclusive Slurm allocation.
EOF
  exit 2
}

[[ $# -ge 1 ]] || usage
: "${AWS_REGION:?AWS_REGION must be set}"

MODE=$1
shift
REMOTE_ROOT=${REMOTE_ROOT:-/fsx/p5-efa-fsx-contention-lab}
SSM_POLL_SECONDS=${SSM_POLL_SECONDS:-5}
SSM_TIMEOUT_SECONDS=${SSM_TIMEOUT_SECONDS:-1800}

[[ ${REMOTE_ROOT} =~ ^/[A-Za-z0-9._/-]+$ ]] || {
  echo "REMOTE_ROOT contains unsupported characters" >&2
  exit 2
}
[[ ${SSM_POLL_SECONDS} =~ ^[0-9]+$ && ${SSM_TIMEOUT_SECONDS} =~ ^[0-9]+$ ]] || {
  echo "SSM poll and timeout values must be unsigned integers" >&2
  exit 2
}

validate_instance_id() {
  [[ $1 =~ ^i-[0-9a-f]{8,17}$ ]] || {
    echo "Invalid EC2 instance ID: $1" >&2
    exit 2
  }
}

validate_label() {
  [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || {
    echo "LABEL may contain only letters, numbers, dot, underscore, and dash" >&2
    exit 2
  }
}

validate_unsigned() {
  [[ $2 =~ ^[0-9]+$ ]] || {
    echo "$1 must be an unsigned integer" >&2
    exit 2
  }
}

send_remote() {
  local instance_id=$1
  local command=$2
  local parameters
  parameters=$(printf '{"commands":["%s"]}' "${command}")
  aws --region "${AWS_REGION}" ssm send-command \
    --instance-ids "${instance_id}" \
    --document-name AWS-RunShellScript \
    --comment "Slurm P5 EFA benchmark ${MODE}" \
    --parameters "${parameters}" \
    --query 'Command.CommandId' \
    --output text
}

wait_remote() {
  local command_id=$1
  local instance_id=$2
  local deadline=$((SECONDS + SSM_TIMEOUT_SECONDS))
  local status

  while (( SECONDS < deadline )); do
    status=$(aws --region "${AWS_REGION}" ssm get-command-invocation \
      --command-id "${command_id}" \
      --instance-id "${instance_id}" \
      --query Status \
      --output text 2>/dev/null || true)
    case "${status}" in
      Success)
        aws --region "${AWS_REGION}" ssm get-command-invocation \
          --command-id "${command_id}" \
          --instance-id "${instance_id}" \
          --query '{Status:Status,Output:StandardOutputContent,Error:StandardErrorContent}'
        return 0
        ;;
      Failed|TimedOut|Cancelled|Cancelling)
        aws --region "${AWS_REGION}" ssm get-command-invocation \
          --command-id "${command_id}" \
          --instance-id "${instance_id}" \
          --query '{Status:Status,Output:StandardOutputContent,Error:StandardErrorContent}' || true
        return 1
        ;;
    esac
    sleep "${SSM_POLL_SECONDS}"
  done

  echo "Timed out waiting for SSM command ${command_id} on ${instance_id}" >&2
  return 1
}

case "${MODE}" in
  nccl)
    [[ $# -ge 4 && $# -le 7 ]] || usage
    WORKER_A=$1
    WORKER_B=$2
    MASTER_ADDR=$3
    LABEL=$4
    RUNTIME_SECONDS=${5:-90}
    TENSOR_MIB=${6:-256}
    START_EPOCH=${7:-$(( $(date +%s) + 60 ))}

    validate_instance_id "${WORKER_A}"
    validate_instance_id "${WORKER_B}"
    validate_label "${LABEL}"
    [[ ${MASTER_ADDR} =~ ^[A-Za-z0-9.-]+$ ]] || {
      echo "MASTER_ADDR contains unsupported characters" >&2
      exit 2
    }
    validate_unsigned SECONDS "${RUNTIME_SECONDS}"
    validate_unsigned TENSOR_MIB "${TENSOR_MIB}"
    validate_unsigned START_EPOCH "${START_EPOCH}"

    COMMAND_A="env MASTER_ADDR=${MASTER_ADDR} NODE_RANK=0 NCCL_RESULT_LABEL=${LABEL} BENCHMARK_SECONDS=${RUNTIME_SECONDS} NCCL_TENSOR_MIB=${TENSOR_MIB} START_AT_EPOCH=${START_EPOCH} ${REMOTE_ROOT}/run_nccl_benchmark_node.sh"
    COMMAND_B="env MASTER_ADDR=${MASTER_ADDR} NODE_RANK=1 NCCL_RESULT_LABEL=${LABEL} BENCHMARK_SECONDS=${RUNTIME_SECONDS} NCCL_TENSOR_MIB=${TENSOR_MIB} START_AT_EPOCH=${START_EPOCH} ${REMOTE_ROOT}/run_nccl_benchmark_node.sh"
    ;;
  checkpoint)
    [[ $# -ge 3 && $# -le 9 ]] || usage
    WORKER_A=$1
    WORKER_B=$2
    LABEL=$3
    MOUNT=${4:-/fsx-efa}
    RUNTIME_SECONDS=${5:-90}
    GPU_INDEX=${6:-0}
    THREADS=${7:-4}
    SIZE_PER_THREAD=${8:-16G}
    START_EPOCH=${9:-$(( $(date +%s) + 60 ))}

    validate_instance_id "${WORKER_A}"
    validate_instance_id "${WORKER_B}"
    validate_label "${LABEL}"
    [[ ${MOUNT} =~ ^/[A-Za-z0-9._/-]+$ ]] || {
      echo "MOUNT contains unsupported characters" >&2
      exit 2
    }
    validate_unsigned SECONDS "${RUNTIME_SECONDS}"
    validate_unsigned GPU "${GPU_INDEX}"
    validate_unsigned THREADS "${THREADS}"
    [[ ${SIZE_PER_THREAD} =~ ^[0-9]+[KMGTP]?$ ]] || {
      echo "SIZE must be an integer optionally followed by K, M, G, T, or P" >&2
      exit 2
    }
    validate_unsigned START_EPOCH "${START_EPOCH}"

    COMMAND_A="env START_AT_EPOCH=${START_EPOCH} ${REMOTE_ROOT}/run_gdsio_checkpoint_write.sh ${LABEL} ${MOUNT} ${RUNTIME_SECONDS} ${GPU_INDEX} ${THREADS} ${SIZE_PER_THREAD}"
    COMMAND_B=${COMMAND_A}
    ;;
  *)
    usage
    ;;
esac

COMMAND_A_ID=$(send_remote "${WORKER_A}" "${COMMAND_A}")
COMMAND_B_ID=$(send_remote "${WORKER_B}" "${COMMAND_B}")

echo "SSM_PAIR_SUBMITTED mode=${MODE} start_epoch=${START_EPOCH}"
echo "worker_a=${WORKER_A} command_a=${COMMAND_A_ID}"
echo "worker_b=${WORKER_B} command_b=${COMMAND_B_ID}"

status=0
wait_remote "${COMMAND_A_ID}" "${WORKER_A}" || status=1
wait_remote "${COMMAND_B_ID}" "${WORKER_B}" || status=1
(( status == 0 )) || exit 1

echo "SSM_PAIR_COMPLETE mode=${MODE} label=${LABEL}"
