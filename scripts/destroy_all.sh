#!/usr/bin/env bash
set -euo pipefail

ENVIRONMENTS=(test dev prod)

for env in "${ENVIRONMENTS[@]}"; do
  echo "=============================="
  echo "Destroying environment: $env"
  echo "=============================="

  if ./scripts/destroy.sh "$env" 2>&1 | tee /tmp/destroy-"$env".log; then
    echo "✔ $env destroyed (or already clean)"
  else
    if grep -qiE "No resources|Nothing to destroy|state.*does not exist" /tmp/destroy-"$env".log; then
      echo "⚠ $env already destroyed — skipping"
    else
      echo "✖ Destroy failed for $env"
      exit 1
    fi
  fi
done
