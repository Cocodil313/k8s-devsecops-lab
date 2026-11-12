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
K -n demo delete sealedsecret demo-secret --ignore-not-found >/dev/null 2>&1
K -n demo delete secret demo-secret --ignore-not-found >/dev/null 2>&1

if ! command -v kubeseal >/dev/null 2>&1; then
  wn "kubeseal absent du PATH"
else
  VAL="s3cr3t-$(date +%s)"
  cat > /tmp/secret.yaml <<SECRET
apiVersion: v1
kind: Secret
metadata:
  name: demo-secret
  namespace: demo
type: Opaque
stringData:
  password: "$VAL"
SECRET

  if kubeseal --controller-name sealed-secrets-controller --controller-namespace kube-system --format yaml < /tmp/secret.yaml > /tmp/sealed.yaml 2>/dev/null; then
    ok "chiffrement reussi"
    grep -q "$VAL" /tmp/sealed.yaml && ko "VALEUR EN CLAIR" || ok "aucune valeur en clair"
    K apply -f /tmp/sealed.yaml >/dev/null 2>&1
    sleep 8
    LU=$(K -n demo get secret demo-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d)
    [ "$LU" = "$VAL" ] && ok "dechiffre par le controleur" || ko "valeur incorrecte"
  else
    ko "kubeseal a echoue"
  fi
  rm -f /tmp/secret.yaml /tmp/sealed.yaml
fi
printf "\n  PASS=%d  FAIL=%d  WARN=%d\n\n" "$PASS" "$FAIL" "$WARN"
if [ "$FAIL" -eq 0 ]; then exit 0; else exit 1; fi
