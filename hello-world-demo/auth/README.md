# auth

[Up to hello-world-demo](../README.md). [Repository overview](../../README.md). The API that shares this pod is [`hello/`](../hello/README.md). The image is built by [`scripts/build-push.sh`](../../scripts/build-push.sh). Istio learns the public key from the URL in [`istio-depoy.yaml`](../../istio-depoy.yaml). How that key is parsed, published, and checked is [How the key works](../../README.md#how-the-key-works). Which paths and headers come from open standards vs. this demo is in [Open standards vs. this demo](../../README.md#open-standards-vs-this-demo).

This folder is the signer image `sol:5000/hello-auth:latest`. The process listens on TCP 8081 and answers GET only. The pod proxy is in front of that port and requires mTLS. The demo gateway routes exact `GET /token` and `GET /.well-known/jwks.json` to this Service for web clients. The pod proxy fetches the JWKS document over mTLS. A meshed pod may call `Service/hello-auth` directly over mTLS. `scripts/test.sh` mints its token with `GET http://192.168.1.3:9090/token`. The gateway results are in [what was recorded](../../README.md#what-was-recorded).

| File | What it is |
|---|---|
| [`main.go`](main.go) | `GET /healthz`, `GET /.well-known/jwks.json`, and `GET /token` (with `Cache-Control: no-store`). The token is `iss=hello-auth`, `sub=demo-user`, `kid=hello-auth-1`, RS256, expiring one hour after issue. Non-GET methods are denied at Envoy (403) and also return 405 in process without signing. Logs omit the token, the modulus, and the exponent. |
| [`key.go`](key.go) | Demo PKCS#8 RSA private key, compiled in so a restart keeps the same `kid`. A deployment mounts this PEM string from a key vault or a similar store, and mounts any other secret the same way. |
| [`main_test.go`](main_test.go) | Signs a token and verifies it against the JWKS document this process publishes, and verifies `POST /token` returns 405. |
| [`Dockerfile`](Dockerfile) | `golang:1.27.4-alpine3.24`. Runs `go test`, builds a static binary, and starts as `nobody`. |
| [`go.mod`](go.mod) | Module `hello-auth`, Go 1.27. |
