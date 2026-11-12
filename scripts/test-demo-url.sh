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
sec "Service"
TYPE=$(K -n demo get svc demo-app -o jsonpath="{.spec.type}" 2>/dev/null)
[ "$TYPE" = "NodePort" ] && ok "Service NodePort" || ko "Service $TYPE"
NP=$(K -n demo get svc demo-app -o jsonpath="{.spec.ports[0].nodePort}" 2>/dev/null)
[ "$NP" = "30080" ] && ok "nodePort 30080" || ko "nodePort $NP"

sec "Endpoints"
EP=$(K -n demo get endpoints demo-app -o jsonpath="{.subsets[*].addresses[*].ip}" 2>/dev/null | wc -w)
[ "${EP:-0}" -ge 1 ] && ok "$EP endpoint(s)" || ko "aucun endpoint"

sec "HTTP"
C1=$(curl -s -o /dev/null -m 8 -w "%{http_code}" http://127.0.0.1:30080 2>/dev/null || echo 000)
[ "$C1" = "200" ] && ok "127.0.0.1:30080 -> 200" || ko "127.0.0.1:30080 -> $C1"
C2=$(curl -s -o /dev/null -m 8 -w "%{http_code}" http://192.168.56.10:30080 2>/dev/null || echo 000)
[ "$C2" = "200" ] && ok "192.168.56.10:30080 -> 200" || ko "192.168.56.10:30080 -> $C2"
printf "\n  PASS=%d  FAIL=%d  WARN=%d\n\n" "$PASS" "$FAIL" "$WARN"
if [ "$FAIL" -eq 0 ]; then exit 0; else exit 1; fi
