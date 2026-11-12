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
if ! command -v trivy >/dev/null 2>&1; then
  wn "trivy absent du PATH"
else
  sec "Scan node:14-alpine (EOL)"
  OUT=$(trivy image --severity CRITICAL --ignore-unfixed --quiet node:14-alpine 2>/dev/null || true)
  N=$(echo "$OUT" | grep -c CRITICAL || true)
  [ "${N:-0}" -gt 0 ] && ok "$N CVE CRITICAL fixables" || wn "aucune CVE CRITICAL"

  sec "Scan image deployee"
  IMG=$(K -n demo get deploy demo-app -o jsonpath="{.spec.template.containers[0].image}" 2>/dev/null)
  if [ -n "${IMG:-}" ]; then
    ok "image : $IMG"
    OUT2=$(trivy image --severity CRITICAL --ignore-unfixed --quiet "$IMG" 2>/dev/null || true)
    N2=$(echo "$OUT2" | grep -c CRITICAL || true)
    ok "$N2 CVE CRITICAL sur l image deployee"
  fi
fi
printf "\n  PASS=%d  FAIL=%d  WARN=%d\n\n" "$PASS" "$FAIL" "$WARN"
if [ "$FAIL" -eq 0 ]; then exit 0; else exit 1; fi
