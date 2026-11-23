#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GATEWAY="${GATEWAY:-http://192.168.1.3:9090}"
APP_NS=hello-world-demo
GW_NS=hello-world-istio
# shellcheck source=lib.sh
source "${ROOT}/scripts/lib.sh"

code_of() {
  curl -sS -m 5 -o /tmp/hello-world-body -w '%{http_code}' "$@"
}

exec_code() {
  local ns=$1 pod=$2
  shift 2
  kubectl exec -n "${ns}" "${pod}" -c client -- curl -sS -m 5 -o /dev/null -w '%{http_code}' "$@"
}

cleanup() {
  kubectl delete pod -n "${APP_NS}" mesh-client --ignore-not-found --wait=false >/dev/null
  kubectl delete pod -n "${GW_NS}" plain-client --ignore-not-found --wait=false >/dev/null
}
trap cleanup EXIT

echo "waiting for ${GATEWAY}"
wait_status 403 "${GATEWAY}/api/v1/hello"
wait_status 200 "${GATEWAY}/healthz"
wait_status 403 -X POST "${GATEWAY}/healthz"
wait_status 200 "${GATEWAY}/token"
wait_status 403 -X POST "${GATEWAY}/token"

# Verify mesh-wide STRICT mTLS and explicit ISTIO_MUTUAL DestinationRules.
pa_mode="$(kubectl get peerauthentication -n istio-system default -o jsonpath='{.spec.mtls.mode}')"
dr_app="$(kubectl get destinationrule -n "${APP_NS}" hello-world -o jsonpath='{.spec.trafficPolicy.tls.mode}')"
dr_auth="$(kubectl get destinationrule -n "${APP_NS}" hello-auth -o jsonpath='{.spec.trafficPolicy.tls.mode}')"

token="$(curl -fsS -m 5 "${GATEWAY}/token")"
if [[ -z "${token}" || "${token}" == *$'\n'* ]]; then
  echo "gateway /token returned an empty or multi-line token" >&2
  exit 1
fi

post_token="$(code_of -X POST "${GATEWAY}/token")"
token_extra="$(code_of "${GATEWAY}/token/extra")"
jwks="$(code_of "${GATEWAY}/.well-known/jwks.json")"
unauth="$(code_of "${GATEWAY}/api/v1/hello")"
health="$(code_of "${GATEWAY}/healthz")"
health_body="$(tr -d '\r\n' < /tmp/hello-world-body)"
post_health="$(code_of -X POST "${GATEWAY}/healthz")"
root="$(code_of "${GATEWAY}/")"
unknown="$(code_of "${GATEWAY}/no-such")"
bad="$(code_of -H "Authorization: Bearer not-a-jwt" "${GATEWAY}/api/v1/hello")"
good=""
body=""
for _ in $(seq 1 50); do
  good="$(code_of -H "Authorization: Bearer ${token}" "${GATEWAY}/api/v1/hello")"
  body="$(tr -d '\r\n' < /tmp/hello-world-body)"
  if [[ "${good}" == "200" && "${body}" == "hello world" ]]; then
    break
  fi
  sleep 0.2
done
authed_unknown="$(code_of -H "Authorization: Bearer ${token}" "${GATEWAY}/no-such")"
authed_post="$(code_of -X POST -H "Authorization: Bearer ${token}" "${GATEWAY}/api/v1/hello")"

app_pod="$(kubectl get pod -n "${APP_NS}" -l app=hello-world -o jsonpath='{.items[0].metadata.name}')"
gw_pod="$(kubectl get pod -n "${GW_NS}" -l istio=hello-ingressgateway -o jsonpath='{.items[0].metadata.name}')"
pod_ip="$(kubectl get pod -n "${APP_NS}" "${app_pod}" -o jsonpath='{.status.podIP}')"
ready="$(kubectl get pod -n "${APP_NS}" "${app_pod}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
containers="$(kubectl get pod -n "${APP_NS}" "${app_pod}" -o jsonpath='{range .status.containerStatuses[*]}{.name}={.ready} {end}{range .status.initContainerStatuses[*]}{.name}={.ready} {end}')"
probes="$(kubectl get pod -n "${APP_NS}" "${app_pod}" -o jsonpath='{range .spec.containers[*]}{.name}={.livenessProbe.httpGet.port}{.livenessProbe.httpGet.path}/{.readinessProbe.httpGet.port}{.readinessProbe.httpGet.path}{" "}{end}')"
app_sa="$(kubectl get pod -n "${APP_NS}" "${app_pod}" -o jsonpath='{.spec.serviceAccountName}:{.spec.automountServiceAccountToken}')"
gw_sa="$(kubectl get pod -n "${GW_NS}" "${gw_pod}" -o jsonpath='{.spec.serviceAccountName}:{.spec.automountServiceAccountToken}')"
gw_roles="$(kubectl get role -n "${GW_NS}" -o jsonpath='{.items[*].metadata.name}')"
hello_probe="$(kubectl logs -n "${APP_NS}" "${app_pod}" -c hello --since=3m | awk '/result=probe/ {line=$0} END {print line}')"
auth_probe="$(kubectl logs -n "${APP_NS}" "${app_pod}" -c auth --since=3m | awk '/path=\/healthz status=200/ {line=$0} END {print line}')"

# Verify no Kubernetes API token is mounted into the app containers.
sa_mounts="none"
for c in hello auth; do
  if kubectl exec -n "${APP_NS}" "${app_pod}" -c "${c}" -- test -e /var/run/secrets/kubernetes.io/serviceaccount/token 2>/dev/null; then
    sa_mounts="present"
  fi
done

# Web client must only enter through the ingress gateway: plaintext and
# unauthenticated TLS to the Pod IP and both ClusterIPs must fail.
direct="closed"
for url in "http://${pod_ip}:8080/healthz" "http://${pod_ip}:8081/healthz" "https://${pod_ip}:8080/healthz"; do
  if curl -ksS -m 3 -o /dev/null "${url}" 2>/dev/null; then
    direct="open"
    echo "web client to ${url} succeeded (want failure)"
  else
    echo "web client to ${url} failed (want failure)"
  fi
done

cluster_ip="$(kubectl get svc -n "${APP_NS}" hello-world -o jsonpath='{.spec.clusterIP}')"
auth_ip="$(kubectl get svc -n "${APP_NS}" hello-auth -o jsonpath='{.spec.clusterIP}')"
cluster_direct="closed"
for url in "http://${cluster_ip}:8080/healthz" "http://${auth_ip}:8081/healthz"; do
  if curl -sS -m 3 -o /dev/null "${url}" 2>/dev/null; then
    cluster_direct="open"
    echo "web client to ${url} succeeded (want failure)"
  else
    echo "web client to ${url} failed (want failure)"
  fi
done

proxy_image="$(kubectl get pod -n "${GW_NS}" "${gw_pod}" -o jsonpath='{.spec.containers[0].image}')"
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: mesh-client
  namespace: ${APP_NS}
  labels:
    app: mesh-client
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext:
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: client
      image: ${proxy_image}
      imagePullPolicy: IfNotPresent
      command: ["sleep", "180"]
      securityContext:
        runAsNonRoot: true
        runAsUser: 1338
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
---
apiVersion: v1
kind: Pod
metadata:
  name: plain-client
  namespace: ${GW_NS}
  labels:
    app: plain-client
  annotations:
    sidecar.istio.io/inject: "false"
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext:
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: client
      image: ${proxy_image}
      imagePullPolicy: IfNotPresent
      command: ["sleep", "180"]
      securityContext:
        runAsNonRoot: true
        runAsUser: 1338
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
EOF

kubectl wait --for=condition=Ready pod/mesh-client -n "${APP_NS}" --timeout=180s
kubectl wait --for=condition=Ready pod/plain-client -n "${GW_NS}" --timeout=180s

mesh_app="$(exec_code "${APP_NS}" mesh-client "http://hello-world.${APP_NS}.svc.cluster.local:8080/api/v1/hello")"
mesh_app_authed="$(exec_code "${APP_NS}" mesh-client -H "Authorization: Bearer ${token}" "http://hello-world.${APP_NS}.svc.cluster.local:8080/api/v1/hello")"
mesh_health="$(exec_code "${APP_NS}" mesh-client "http://hello-world.${APP_NS}.svc.cluster.local:8080/healthz")"
mesh_other="$(exec_code "${APP_NS}" mesh-client "http://hello-world.${APP_NS}.svc.cluster.local:8080/token")"
mesh_auth_health="$(exec_code "${APP_NS}" mesh-client "http://hello-auth.${APP_NS}.svc.cluster.local:8081/healthz")"
mesh_token="$(exec_code "${APP_NS}" mesh-client "http://hello-auth.${APP_NS}.svc.cluster.local:8081/token")"

plain="closed"
for url in \
  "http://hello-world.${APP_NS}.svc.cluster.local:8080/healthz" \
  "http://hello-auth.${APP_NS}.svc.cluster.local:8081/healthz"; do
  if kubectl exec -n "${GW_NS}" plain-client -c client -- curl -sS -m 5 -o /dev/null "${url}" >/dev/null 2>&1; then
    plain="open"
  fi
done

mtls="missing"
plain_accepted="no"
stats="$(kubectl exec -n "${APP_NS}" "${app_pod}" -c istio-proxy -- pilot-agent request GET stats 2>/dev/null)"
if grep -q 'source_workload\.mesh-client.*destination_principal\.spiffe://cluster\.local/ns/hello-world-demo/sa/hello-world.*destination_service_name\.hello-world.*response_code\.200.*connection_security_policy\.mutual_tls' <<<"${stats}" \
  && grep -q 'source_workload\.mesh-client.*destination_service_name\.hello-world.*response_code\.403.*connection_security_policy\.mutual_tls' <<<"${stats}" \
  && grep -q 'source_workload\.hello-ingressgateway.*source_principal\.spiffe://cluster\.local/ns/hello-world-istio/sa/hello-ingressgateway.*destination_principal\.spiffe://cluster\.local/ns/hello-world-demo/sa/hello-world.*connection_security_policy\.mutual_tls' <<<"${stats}"; then
  mtls="mutual_tls"
fi
if grep -q 'istio_requests_total.*response_code\.200.*connection_security_policy\.none' <<<"${stats}"; then
  plain_accepted="yes"
fi

secret_leaks="none"
for c in hello auth; do
  if kubectl logs -n "${APP_NS}" "${app_pod}" -c "${c}" 2>/dev/null | grep -Eq 'eyJ|BEGIN.*PRIVATE KEY'; then
    secret_leaks="found"
  fi
done

echo "mesh PeerAuthentication istio-system/default: ${pa_mode} (want STRICT)"
echo "DestinationRules: hello-world=${dr_app} hello-auth=${dr_auth} (want ISTIO_MUTUAL)"
echo "gateway no token /api/v1/hello: ${unauth} (want 403)"
echo "gateway no token /: ${root} (want 403)"
echo "gateway no token /no-such: ${unknown} (want 403)"
echo "gateway no token /token/extra: ${token_extra} (want 403)"
echo "gateway POST /healthz: ${post_health} (want 403)"
echo "gateway POST /token: ${post_token} (want 403)"
echo "gateway GET /healthz: ${health} body=${health_body} (want 200 ok)"
echo "gateway jwks: ${jwks} (want 200)"
echo "gateway bad token: ${bad} (want 401)"
echo "gateway good token: ${good} body=${body} (want 200 hello world)"
echo "gateway authed /no-such: ${authed_unknown} (want 404)"
echo "gateway authed POST /api/v1/hello: ${authed_post} (want 405)"
echo "pod ready: ${ready} containers: ${containers}"
echo "pod probe ports: ${probes}"
echo "hello probe log: ${hello_probe:-none}"
echo "auth probe log: ${auth_probe:-none}"
echo "identities: app=${app_sa} gw=${gw_sa} gw_roles=${gw_roles:-none} app_sa_token=${sa_mounts}"
echo "mesh pod to hello /api/v1/hello (no token): ${mesh_app} (want 403)"
echo "mesh pod to hello /api/v1/hello (with token): ${mesh_app_authed} (want 200)"
echo "mesh pod to hello /healthz: ${mesh_health} (want 200)"
echo "mesh pod to hello /token: ${mesh_other} (want 403)"
echo "mesh pod to signer /healthz: ${mesh_auth_health} (want 200)"
echo "mesh pod to signer /token: ${mesh_token} (want 200)"
echo "plain pod to hello and signer: ${plain} (want closed)"
echo "pod-to-pod security: ${mtls} plaintext_200=${plain_accepted} (want mutual_tls no)"
echo "secret leaks in app logs: ${secret_leaks} (want none)"

probe_ok=no
[[ "${ready}" == "True" \
  && "${containers}" == *"hello=true"* && "${containers}" == *"auth=true"* && "${containers}" == *"istio-proxy=true"* \
  && "${probes}" == *"hello=15020/app-health/hello/livez/15020/app-health/hello/readyz"* \
  && "${probes}" == *"auth=15020/app-health/auth/livez/15020/app-health/auth/readyz"* \
  && "${hello_probe}" == *"result=probe"* \
  && "${auth_probe}" == *"status=200"* ]] && probe_ok=yes

[[ "${pa_mode}" == "STRICT" && "${dr_app}" == "ISTIO_MUTUAL" && "${dr_auth}" == "ISTIO_MUTUAL" \
  && "${unauth}" == "403" && "${root}" == "403" && "${unknown}" == "403" && "${token_extra}" == "403" \
  && "${post_health}" == "403" && "${post_token}" == "403" \
  && "${health}" == "200" && "${health_body}" == "ok" && "${jwks}" == "200" && "${bad}" == "401" \
  && "${good}" == "200" && "${body}" == "hello world" && "${authed_unknown}" == "404" \
  && "${authed_post}" == "405" && "${direct}" == "closed" && "${cluster_direct}" == "closed" \
  && "${probe_ok}" == "yes" && "${app_sa}" == "hello-world:false" && "${gw_sa}" == "hello-ingressgateway:false" \
  && -z "${gw_roles}" && "${sa_mounts}" == "none" \
  && "${mesh_app}" == "403" && "${mesh_app_authed}" == "200" && "${mesh_health}" == "200" \
  && "${mesh_other}" == "403" && "${mesh_auth_health}" == "200" && "${mesh_token}" == "200" \
  && "${plain}" == "closed" && "${mtls}" == "mutual_tls" && "${plain_accepted}" == "no" \
  && "${secret_leaks}" == "none" ]]
