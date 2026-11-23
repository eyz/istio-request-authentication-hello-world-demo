wait_status() {
  local want=$1
  shift
  local code=""
  local _
  for _ in $(seq 1 50); do
    code="$(curl -sS -m 2 -o /dev/null -w '%{http_code}' "$@" 2>/dev/null || true)"
    if [[ "${code}" == "${want}" ]]; then
      return 0
    fi
    sleep 0.2
  done
  echo "timed out waiting for $* to return ${want}, last status was ${code:-none}" >&2
  return 1
}
