#!/usr/bin/env bash
set -u
PASS=0; FAIL=0; WARN=0
C_G='\033[32m'; C_R='\033[31m'; C_Y='\033[33m'; C_C='\033[36m'; C_0='\033[0m'
ok()  { printf "  ${C_G}[PASS]${C_0} %s\n" "$*"; PASS=$((PASS+1)); }
ko()  { printf "  ${C_R}[FAIL]${C_0} %s\n" "$*"; FAIL=$((FAIL+1)); }
wn()  { printf "  ${C_Y}[WARN]${C_0} %s\n" "$*"; WARN=$((WARN+1)); }
sec() { printf "\n${C_C}== %s ==${C_0}\n" "$*"; }
K() {
  if sudo test -r /etc/rancher/k3s/k3s.yaml 2>/dev/null; then
    sudo kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml "$@"
  elif [ -r "$HOME/.kube/config" ]; then
    kubectl "$@"
  else
    echo "ERREUR: kubectl non configure" >&2
    return 1
  fi
}
sec "Policies"
N=$(K get validatingpolicy --no-headers 2>/dev/null | wc -l)
[ "${N:-0}" -ge 2 ] && ok "$N ValidatingPolicy" || ko "$N policy"

sec "Rejet :latest"
cat > /tmp/bad.yaml <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: test-bad-latest
  namespace: demo
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: c
      image: nginx:latest
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
      resources:
        limits:
          cpu: 100m
          memory: 64Mi
YAML
OUT=$(K apply -f /tmp/bad.yaml 2>&1 || true)
echo "$OUT" | grep -q "disallow-latest-tag" && ok "rejete par Kyverno" || ko "pod accepte"
K -n demo delete pod test-bad-latest --ignore-not-found >/dev/null 2>&1
rm -f /tmp/bad.yaml
printf "\n  PASS=%d  FAIL=%d  WARN=%d\n\n" "$PASS" "$FAIL" "$WARN"
if [ "$FAIL" -eq 0 ]; then exit 0; else exit 1; fi
