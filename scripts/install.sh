#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REGISTRY="${REGISTRY:-sol:5000}"
GATEWAY="${GATEWAY:-http://192.168.1.3:9090}"
# shellcheck source=lib.sh
source "${ROOT}/scripts/lib.sh"

kubectl scale statefulset/registry -n infra --replicas=1
kubectl rollout status statefulset/registry -n infra --timeout=180s

for repo in hello-world hello-auth; do
  if ! curl -fsS -m 5 "http://${REGISTRY}/v2/${repo}/tags/list" | grep -q latest; then
    echo "missing ${REGISTRY}/${repo}:latest; run scripts/build-push.sh first" >&2
    exit 1
  fi
done

kubectl apply -f "${ROOT}/hello-world-demo/deploy.yml"
kubectl rollout status deployment/hello-world -n hello-world-demo --timeout=180s

# Envoy fetches in-mesh JWKS over mTLS. Value "true" means Envoy, with istiod
# as the fallback only when the JWKS host is outside the mesh.
# https://istio.io/v1.32/docs/reference/commands/pilot-discovery/
kubectl set env deployment/istiod -n istio-system PILOT_JWT_ENABLE_REMOTE_JWKS=true
kubectl rollout status deployment/istiod -n istio-system --timeout=180s

kubectl apply -f "${ROOT}/istio-depoy.yaml"
kubectl rollout status deployment/hello-ingressgateway -n hello-world-istio --timeout=180s

wait_status 403 "${GATEWAY}/api/v1/hello"
wait_status 200 "${GATEWAY}/healthz"
wait_status 200 "${GATEWAY}/.well-known/jwks.json"
wait_status 200 "${GATEWAY}/token"
echo "gateway ${GATEWAY} is ready: /api/v1/hello returned 403 without a token, and /healthz, JWKS, and /token returned 200"
