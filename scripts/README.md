# scripts

[Up to the repository](../README.md). These scripts build [`hello-world-demo`](../hello-world-demo/README.md), including [`hello/`](../hello-world-demo/hello/README.md) and [`auth/`](../hello-world-demo/auth/README.md), and apply [`istio-depoy.yaml`](../istio-depoy.yaml).

Run them on the k3s host, from the repository root. `kubectl` is the k3s binary and reads `/etc/rancher/k3s/k3s.yaml`.

| Script | What it does |
|---|---|
| [`build-push.sh`](build-push.sh) | Requires `sol:5000` to answer, then builds both Dockerfiles and pushes `sol:5000/hello-world:latest` and `sol:5000/hello-auth:latest`. `REGISTRY` overrides the registry host. |
| [`install.sh`](install.sh) | Scales StatefulSet `registry` in `infra` to 1, stops if either `latest` tag is missing, applies `hello-world-demo/deploy.yml` and waits for rollout, sets `PILOT_JWT_ENABLE_REMOTE_JWKS=true` on `istiod`, applies `istio-depoy.yaml` and waits for `hello-ingressgateway`, and requires 403 from `/api/v1/hello` and 200 from `/healthz`, `/.well-known/jwks.json`, and `/token` on the gateway. Idempotent under STRICT mTLS (no port-forward). |
| [`test.sh`](test.sh) | Mints a token at `http://192.168.1.3:9090/token`. Verifies mesh-wide `STRICT` mTLS and `ISTIO_MUTUAL` DestinationRules, default-deny on the hello app and signer, `GET /healthz` 200, rewritten kubelet probes, dedicated ServiceAccounts with no mounted K8s API token and no Secret-reading Roles, plaintext and unauthenticated-TLS rejection from this host, pod-to-pod `mutual_tls` from a mesh pod (unauthenticated and authenticated), rejection of a non-sidecar pod on both ports, and zero secret leaks in container logs. Deletes the client pods on exit. |
| [`lib.sh`](lib.sh) | `wait_status`. Sourced by `install.sh` and `test.sh`. Polls an HTTP status code with optional curl flags and discards transient connection-refused noise. |

```bash
scripts/build-push.sh
scripts/install.sh
scripts/test.sh
```

`test.sh` at `2026-11-23T21:15:26Z` passed every check above. The pod was Ready, both probes logged `GET /healthz` 200, a mesh pod used `mutual_tls` with zero plaintext 200s, and a pod without a sidecar was rejected on both ports. The full printout is in the [repository README](../README.md#what-was-recorded).
