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
sec "Noeuds"
NB=$(K get nodes --no-headers 2>/dev/null | wc -l)
READY=$(K get nodes --no-headers 2>/dev/null | grep -c " Ready " || true)
[ "$NB" -eq 3 ] && ok "3 noeuds" || ko "$NB noeuds"
[ "${READY:-0}" -eq 3 ] && ok "3 Ready" || ko "${READY:-0} Ready"

sec "CNI"
KP=$(K -n kube-system get pods --no-headers 2>/dev/null | grep -c kube-proxy || true)
[ "${KP:-0}" -eq 0 ] && ok "kube-proxy absent" || ko "$KP kube-proxy"
CIL=$(K -n kube-system get ds cilium -o jsonpath="{.status.numberReady}" 2>/dev/null)
[ "${CIL:-0}" -eq 3 ] && ok "cilium 3/3" || ko "cilium ${CIL:-0}/3"

sec "Falco"
FAL=$(K -n falco get pods --no-headers 2>/dev/null | grep -c Running || true)
[ "${FAL:-0}" -eq 3 ] && ok "falco 3/3" || ko "falco ${FAL:-0}/3"

sec "Sealed Secrets"
K -n kube-system get deploy sealed-secrets-controller >/dev/null 2>&1 && ok "controleur" || ko "controleur absent"
[ -s /home/vagrant/backups/sealed-secrets-key.yaml ] && ok "cle sauvegardee" || ko "cle absente"

sec "Tunnels"
systemctl is-active --quiet pf-argocd && ok "pf-argocd" || ko "pf-argocd"
systemctl is-active --quiet pf-grafana && ok "pf-grafana" || ko "pf-grafana"
printf "\n  PASS=%d  FAIL=%d  WARN=%d\n\n" "$PASS" "$FAIL" "$WARN"
if [ "$FAIL" -eq 0 ]; then exit 0; else exit 1; fi
