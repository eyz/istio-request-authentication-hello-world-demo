# hello

[Up to hello-world-demo](../README.md). [Repository overview](../../README.md). The signer that shares this pod is [`auth/`](../auth/README.md). The image is built by [`scripts/build-push.sh`](../../scripts/build-push.sh).

This folder is the API image `sol:5000/hello-world:latest`. The process listens on TCP 8080 and answers GET only. At `2026-11-23T21:15:38Z` the pod was Ready. Kubelet probes are rewritten to port 15020, and this process logged `GET /healthz` `200` `result=probe user=none`. `GET /api/v1/hello` without a token was 403 from the proxy and did not appear in this process's log. A call that arrived through the gateway with a valid token was logged `result=served` with `iss=hello-auth` and `sub=demo-user`. The captured headers are in the [repository README](../../README.md#what-was-recorded).

| File | What it is |
|---|---|
| [`main.go`](main.go) | `GET /api/v1/hello` returns `hello world`. `GET /healthz` returns `ok` for the Kubernetes probe. Any other path is 404. Any other method is 405. It base64-decodes `iss` and `sub` from the bearer payload for the log line and does not check the signature. The proxy, not this process, rejects a caller who has no token. See [which requests must carry a token](../../README.md#which-requests-must-carry-a-token). |
| [`main_test.go`](main_test.go) | Checks identity logging for a missing header, an unreadable token, and `iss` plus `sub`. The log line must not contain the token. |
| [`Dockerfile`](Dockerfile) | `golang:1.27.4-alpine3.24`. Runs `go test`, builds a static binary, and starts as `nobody`. |
| [`go.mod`](go.mod) | Module `hello-world`, Go 1.27. |
