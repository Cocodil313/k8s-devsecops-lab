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
sec "Etat initial"
RUN=$(K -n demo get pods -l app=demo-app --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
[ "${RUN:-0}" -ge 2 ] && ok "$RUN pods Running" || ko "$RUN pod"
C=$(curl -s -o /dev/null -m 8 -w "%{http_code}" http://127.0.0.1:30080 2>/dev/null || echo 000)
[ "$C" = "200" ] && ok "URL repond avant" || ko "URL $C"

sec "Suppression d un pod"
CIBLE=$(K -n demo get pods -l app=demo-app --field-selector=status.phase=Running -o jsonpath="{.items[0].metadata.name}" 2>/dev/null)
if [ -n "${CIBLE:-}" ]; then
  K -n demo delete pod "$CIBLE" --wait=false >/dev/null 2>&1
  OKC=0; TOT=0
  for i in $(seq 1 15); do
    C=$(curl -s -o /dev/null -m 4 -w "%{http_code}" http://127.0.0.1:30080 2>/dev/null || echo 000)
    TOT=$((TOT+1))
    [ "$C" = "200" ] && OKC=$((OKC+1))
    sleep 2
  done
  PCT=$((OKC*100/TOT))
  [ "$PCT" -ge 80 ] && ok "URL disponible $OKC/$TOT ($PCT%)" || ko "URL disponible $OKC/$TOT ($PCT%)"
else
  ko "aucun pod a supprimer"
fi

sec "Reschedule"
sleep 20
RUN2=$(K -n demo get pods -l app=demo-app --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
[ "${RUN2:-0}" -ge 2 ] && ok "$RUN2 pods Running" || ko "$RUN2 pod"
C=$(curl -s -o /dev/null -m 8 -w "%{http_code}" http://127.0.0.1:30080 2>/dev/null || echo 000)
[ "$C" = "200" ] && ok "URL repond apres" || ko "URL $C"
printf "\n  PASS=%d  FAIL=%d  WARN=%d\n\n" "$PASS" "$FAIL" "$WARN"
if [ "$FAIL" -eq 0 ]; then exit 0; else exit 1; fi
