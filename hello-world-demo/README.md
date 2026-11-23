# hello-world-demo

[Up to the repository](../README.md). The gateway, mesh-wide mTLS policy, and JWT policies in front of this pod are [`istio-depoy.yaml`](../istio-depoy.yaml). The scripts that build and install this folder are [`scripts/`](../scripts/README.md).

This folder is namespace `hello-world-demo`. [`deploy.yml`](deploy.yml) creates that namespace with `istio-injection: enabled`, dedicated `ServiceAccount/hello-world` (`automountServiceAccountToken: false`), Deployment `hello-world`, and Services `hello-world` (port 8080) and `hello-auth` (port 8081, named `http-auth`). Both Services select `app: hello-world`. The images are `sol:5000/hello-world:latest` and `sol:5000/hello-auth:latest`, pulled with `imagePullPolicy: Always`.

| Path | What it is |
|---|---|
| [`deploy.yml`](deploy.yml) | Namespace, ServiceAccount, Deployment, and both Services. |
| [`hello/`](hello/README.md) | The API container. Listens on 8080. |
| [`auth/`](auth/README.md) | The signer container. Listens on 8081. |

`hello` and `auth` share the pod network namespace, so they bind different ports. Both ports are redirected to `istio-proxy`. Mesh-wide `PeerAuthentication` STRICT in `istio-system` requires mTLS from the gateway and from any other pod. `sidecar.istio.io/rewriteAppHTTPProbers: "true"` sends kubelet probes of both containers to the sidecar agent on port 15020. `AuthorizationPolicy/hello-world-deny-all` and `AuthorizationPolicy/hello-world` default-deny port 8080 except for a validated JWT or `GET /healthz`, and open port 8081 only to `GET /healthz`, `GET /token`, and `GET /.well-known/jwks.json`. Web clients reach those paths only through the gateway. Both containers run as non-root (`65534:65534`), drop all capabilities, use a read-only root filesystem, run under `RuntimeDefault` seccomp, and receive no Kubernetes API token. The `/healthz` rule is the [Istio example](https://istio.io/v1.32/docs/reference/config/security/request_authentication/). The capture is in [what was recorded](../README.md#what-was-recorded).
