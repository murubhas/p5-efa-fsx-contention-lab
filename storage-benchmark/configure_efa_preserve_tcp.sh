#!/usr/bin/env bash
set -euo pipefail

# Live-lab variant of the AWS FSx EFA setup. It intentionally preserves the
# existing LNet TCP network because ParallelCluster already has /fsx mounted.
# For durable node bootstrap, run AWS's official setup.sh before mounting FSx.

MODE=${1:-regular}
DEFAULT_INTERFACE=${2:-$(ip -o -4 route show default | awk 'NR==1 {print $5}')}

if [[ ${EUID} -ne 0 ]]; then
  echo "Run as root" >&2
  exit 1
fi

if ! lnetctl net show --net tcp >/dev/null 2>&1; then
  echo "Expected an existing LNet TCP network; refusing to continue" >&2
  exit 1
fi

mapfile -t ALL_EFA < <(
  for path in /sys/class/infiniband/*; do
    [[ -e "${path}/device/driver" ]] || continue
    [[ $(basename "$(realpath "${path}/device/driver")") == efa ]] || continue
    basename "${path}"
  done | sort -V
)

if [[ ${#ALL_EFA[@]} -eq 0 ]]; then
  echo "No EFA devices found" >&2
  exit 1
fi

case "${MODE}" in
  regular)
    # p5.48xlarge exposes 32 devices. AWS's regular-I/O default selects one
    # device per PCI bus: interfaces 1, 5, 9, ... in the sorted list.
    SELECTED_EFA=()
    for ((index = 0; index < ${#ALL_EFA[@]}; index += 4)); do
      SELECTED_EFA+=("${ALL_EFA[index]}")
    done
    PEER_CREDITS=128
    ;;
  gds)
    # AWS's --optimized-for-gds path uses every available EFA interface.
    SELECTED_EFA=("${ALL_EFA[@]}")
    PEER_CREDITS=128
    ;;
  *)
    echo "Mode must be regular or gds" >&2
    exit 1
    ;;
esac

modprobe lnet
modprobe kefalnd "ipif_name=${DEFAULT_INTERFACE}"
modprobe ksocklnd
lnetctl lnet configure >/dev/null 2>&1 || true

EXISTING_EFA_NIDS=$(lnetctl net show --net efa 2>/dev/null | grep -c '@efa' || true)
if [[ ${EXISTING_EFA_NIDS} -gt 0 ]]; then
  echo "EFA LNet is already configured; refusing to stack another configuration" >&2
  lnetctl net show --net efa
  exit 1
fi

for device in "${SELECTED_EFA[@]}"; do
  lnetctl net add --net efa --if "${device}" --peer-credits "${PEER_CREDITS}"
done

lnetctl set discovery 1
set +e
UDSP_OUTPUT=$(lnetctl udsp add --src efa --priority 0 2>&1)
UDSP_STATUS=$?
set -e
if [[ ${UDSP_STATUS} -ne 0 && ${UDSP_STATUS} -ne 114 && ${UDSP_OUTPUT} != *"Operation already in progress"* ]]; then
  echo "${UDSP_OUTPUT}" >&2
  exit "${UDSP_STATUS}"
fi

modprobe lustre
EFA_NID_COUNT=$(lnetctl net show --net efa | grep -c '@efa')
if [[ ${EFA_NID_COUNT} -ne ${#SELECTED_EFA[@]} ]]; then
  echo "Expected ${#SELECTED_EFA[@]} EFA NIDs; found ${EFA_NID_COUNT}" >&2
  exit 1
fi

echo "FSX_EFA_LNET_READY mode=${MODE} tcp=${DEFAULT_INTERFACE} efa_nids=${EFA_NID_COUNT}"
lnetctl net show
