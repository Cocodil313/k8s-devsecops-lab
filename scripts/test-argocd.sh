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
sec "Applications"
APPS=$(K -n argocd get applications --no-headers 2>/dev/null | wc -l)
[ "${APPS:-0}" -ge 2 ] && ok "$APPS application(s)" || ko "$APPS application(s)"
for app in root demo-app; do
  SYNC=$(K -n argocd get application "$app" -o jsonpath="{.status.sync.status}" 2>/dev/null)
  HEALTH=$(K -n argocd get application "$app" -o jsonpath="{.status.health.status}" 2>/dev/null)
  [ "$SYNC" = "Synced" ] && ok "$app Synced" || ko "$app $SYNC"
  [ "$HEALTH" = "Healthy" ] && ok "$app Healthy" || ko "$app $HEALTH"
done

sec "HPA ignoreDifferences"
ID=$(K -n argocd get application demo-app -o jsonpath="{.spec.ignoreDifferences}" 2>/dev/null)
echo "$ID" | grep -q "/spec/replicas" && ok "ignoreDifferences present" || ko "absent"
printf "\n  PASS=%d  FAIL=%d  WARN=%d\n\n" "$PASS" "$FAIL" "$WARN"
if [ "$FAIL" -eq 0 ]; then exit 0; else exit 1; fi
