#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

required_files=(
  README.md
  LICENSE
  CONTRIBUTING.md
  cluster.template.yaml
  docs/p5-efa-fsx-contention-animation.html
  assets/p5-fsx-efa-gds-contention.svg
  assets/p5-fsx-efa-gds-contention.png
  assets/p5-efa-measurement-attribution.svg
  assets/p5-efa-measurement-attribution.png
  results/fsx-efa-gds-contention-validation.md
  results/fsx-efa-gds-contention-summary.json
  storage-benchmark/README.md
  storage-benchmark/REPRODUCTION.md
  storage-benchmark/METRICS.md
  storage-benchmark/collect_worker_inventory.sh
  storage-benchmark/configure_efa_preserve_tcp.sh
  storage-benchmark/install_nvidia_fs.sh
  storage-benchmark/run_fio_transport.sh
  storage-benchmark/run_gdsio_checkpoint_write.sh
  storage-benchmark/run_gdsio_transport.sh
  storage-benchmark/nccl_allreduce_benchmark.py
  storage-benchmark/run_nccl_benchmark_node.sh
  storage-benchmark/run_nccl_slurm_step.sh
  storage-benchmark/run_ssm_pair.sh
  storage-benchmark/summarize_efa_hardware_counters.py
  terraform/main.tf
  terraform/tests/cluster_contract.tftest.hcl
  scripts/verify_efa_fsx_animation.mjs
)

for file in "${required_files[@]}"; do
  if [[ ! -f "${file}" ]]; then
    echo "Missing required publication artifact: ${file}" >&2
    exit 1
  fi
done

sensitive_pattern='arn:aws[a-z-]*:[^:[:space:]]*:[^:[:space:]]*:[0-9]{12}:|(AWS_ACCOUNT_ID|aws_account_id|account[_ -]?(id|number))[^0-9]{0,12}[0-9]{12}|/Users/[^/[:space:]]+|[A-Za-z0-9._%+-]+@amazon\.com|(AKIA|ASIA)[A-Z0-9]{16}|10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}'
if [[ -n "${PUBLICATION_PRIVATE_PATTERN:-}" ]]; then
  sensitive_pattern="${sensitive_pattern}|${PUBLICATION_PRIVATE_PATTERN}"
fi

scan_sensitive_content() {
  if command -v rg >/dev/null 2>&1; then
    rg -n --hidden \
      --glob '!.git/**' \
      --glob '!node_modules/**' \
      --glob '!terraform/.terraform/**' \
      --glob '!assets/*.png' \
      --glob '!assets/*.svg' \
      --glob '!scripts/publication_check.sh' \
      "${sensitive_pattern}" .
  else
    grep -E -R -n -I \
      --exclude-dir=.git \
      --exclude-dir=node_modules \
      --exclude-dir=.terraform \
      --exclude='*.png' \
      --exclude='*.svg' \
      --exclude=publication_check.sh \
      "${sensitive_pattern}" .
  fi
}

if scan_sensitive_content; then
  echo "Publication scan found environment-specific or sensitive content" >&2
  exit 1
fi

resource_id_pattern='(vpc|subnet|sg|fs|ami)-[0-9a-f]{8,}'

scan_resource_ids() {
  if command -v rg >/dev/null 2>&1; then
    rg -n --hidden \
      --glob '!.git/**' \
      --glob '!node_modules/**' \
      --glob '!terraform/.terraform/**' \
      --glob '!terraform/tests/**' \
      --glob '!terraform/terraform.tfvars.example' \
      --glob '!assets/*.png' \
      --glob '!assets/*.svg' \
      --glob '!scripts/publication_check.sh' \
      "${resource_id_pattern}" .
  else
    grep -E -R -n -I \
      --exclude-dir=.git \
      --exclude-dir=node_modules \
      --exclude-dir=.terraform \
      --exclude-dir=tests \
      --exclude=terraform.tfvars.example \
      --exclude='*.png' \
      --exclude='*.svg' \
      --exclude=publication_check.sh \
      "${resource_id_pattern}" .
  fi
}

if scan_resource_ids; then
  echo "Publication scan found concrete AWS resource IDs" >&2
  exit 1
fi

forbidden_files="$(find . -type f \( \
  -name '*.tfstate' -o \
  -name '*.tfstate.*' -o \
  -name '*.tfplan' -o \
  -name '*.pem' -o \
  -name '*.key' -o \
  -name 'kubeconfig*' -o \
  -name '.env' -o \
  -name '*.log' -o \
  -name '*.out' -o \
  -name '*.err' \
\) -not -path './node_modules/*' -not -path './terraform/.terraform/*' -print)"

if [[ -n "${forbidden_files}" ]]; then
  echo "Publication scan found files that must not be committed:" >&2
  printf '%s\n' "${forbidden_files}" >&2
  exit 1
fi

echo "PUBLICATION_CHECK_PASSED"
