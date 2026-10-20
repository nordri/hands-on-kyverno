#!/usr/bin/env bash
set -euo pipefail

KIND="${KIND:-kind}"
CLUSTER_NAME="${CLUSTER_NAME:-kyverno-lab}"

echo "Destroying Kind cluster '${CLUSTER_NAME}' and all its resources..."
"${KIND}" delete cluster --name "${CLUSTER_NAME}"
