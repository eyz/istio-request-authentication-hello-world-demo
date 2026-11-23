#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REGISTRY="${REGISTRY:-sol:5000}"

if ! curl -fsS -m 3 "http://${REGISTRY}/v2/" >/dev/null; then
  echo "registry ${REGISTRY} is not reachable" >&2
  exit 1
fi

docker build -t "${REGISTRY}/hello-world:latest" "${ROOT}/hello-world-demo/hello"
docker build -t "${REGISTRY}/hello-auth:latest" "${ROOT}/hello-world-demo/auth"
docker push "${REGISTRY}/hello-world:latest"
docker push "${REGISTRY}/hello-auth:latest"
