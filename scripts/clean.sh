#!/usr/bin/env bash
set -euo pipefail

KUBECTL="${KUBECTL:-kubectl}"
CLUSTER_NAME="${CLUSTER_NAME:-kyverno-lab}"
KUBE_CONTEXT="kind-${CLUSTER_NAME}"

echo "Cleaning PoV resources from ${KUBE_CONTEXT} (keeping infrastructure)..."

# Fail safely if the intended cluster is missing or inaccessible.
"${KUBECTL}" --context "${KUBE_CONTEXT}" get namespace argocd >/dev/null
"${KUBECTL}" --context "${KUBE_CONTEXT}" get namespace development >/dev/null

# Disable reconciliation before removing the Applications.
for app in kyverno-policies kyverno-workloads; do
  if "${KUBECTL}" --context "${KUBE_CONTEXT}" -n argocd get application "${app}" >/dev/null 2>&1; then
    "${KUBECTL}" --context "${KUBE_CONTEXT}" -n argocd patch application "${app}" \
      --type=merge -p '{"spec":{"syncPolicy":{"automated":null}}}'
  fi
done

# Argo CD may delete tracked resources through Application finalizers.
"${KUBECTL}" --context "${KUBE_CONTEXT}" -n argocd delete application \
  kyverno-policies kyverno-workloads --ignore-not-found --wait=true

# Delete only named PoV objects, including those created outside GitOps.
"${KUBECTL}" --context "${KUBE_CONTEXT}" -n development delete pod \
  nginx-gitops --ignore-not-found
"${KUBECTL}" --context "${KUBE_CONTEXT}" delete validatingpolicy \
  disallow-privileged disallow-latest allowed-registries --ignore-not-found
"${KUBECTL}" --context "${KUBE_CONTEXT}" delete mutatingpolicy \
  add-managed-label add-managed-label-2 --ignore-not-found

echo "PoV cleaned. Kind, Argo CD, Kyverno and namespaces remain installed."
