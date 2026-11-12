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
if ! command -v docker >/dev/null 2>&1 && ! command -v gitleaks >/dev/null 2>&1; then
  wn "docker et gitleaks absents : test non execute"
else
  cat > /tmp/leak.txt <<'LEAK'
-----BEGIN RSA PRIVATE KEY-----
MIIEowIBAAKCAQEAz7X9QW3LMN5PQR2TbGhJkLmNpQrStUvWxYz0123456789abcdef
-----END RSA PRIVATE KEY-----
LEAK

  sec "Detection"
  if command -v gitleaks >/dev/null 2>&1; then
    OUT=$(gitleaks detect --source=/tmp --no-git --verbose --exit-code 1 2>&1 || true)
  else
    OUT=$(docker run --rm -v "/tmp:/scan" zricethezav/gitleaks:latest detect --source=/scan --no-git --verbose --exit-code 1 2>&1 || true)
  fi
  echo "$OUT" | grep -qiE "private-key|private key" && ok "secret detecte" || ko "non detecte"
  rm -f /tmp/leak.txt
fi
printf "\n  PASS=%d  FAIL=%d  WARN=%d\n\n" "$PASS" "$FAIL" "$WARN"
if [ "$FAIL" -eq 0 ]; then exit 0; else exit 1; fi
