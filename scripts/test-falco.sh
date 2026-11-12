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
sec "DaemonSet"
N=$(K -n falco get pods --no-headers 2>/dev/null | grep -c Running || true)
[ "${N:-0}" -eq 3 ] && ok "3 pods Falco" || ko "$N pods"

sec "Detection"
K -n default delete pod falco-test --ignore-not-found >/dev/null 2>&1
K run falco-test --image=debian:13-slim --restart=Never -n default --command -- sh -c "apt-get update >/dev/null 2>&1; ln -sf /bin/sleep /tmp/xmrig; /tmp/xmrig 2" >/dev/null 2>&1
sleep 25
ALERTES=$(K -n falco logs -l app.kubernetes.io/name=falco -c falco --tail=1000 --prefix 2>/dev/null | grep -ciE "package management|Crypto miner" || true)
[ "${ALERTES:-0}" -ge 1 ] && ok "$ALERTES alerte(s)" || ko "aucune alerte"
K -n default delete pod falco-test --ignore-not-found >/dev/null 2>&1
printf "\n  PASS=%d  FAIL=%d  WARN=%d\n\n" "$PASS" "$FAIL" "$WARN"
if [ "$FAIL" -eq 0 ]; then exit 0; else exit 1; fi
