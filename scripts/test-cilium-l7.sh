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
cat > /tmp/attacker.yaml <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: attacker
  namespace: demo
  labels:
    app: attacker
spec:
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    runAsGroup: 1000
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: attacker
      image: busybox:1.36
      command: ["sh", "-c", "sleep 600"]
      resources:
        requests: { cpu: 10m, memory: 8Mi }
        limits:   { cpu: 50m, memory: 32Mi }
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      volumeMounts:
        - { name: tmp, mountPath: /tmp }
  volumes:
    - { name: tmp, emptyDir: {} }
YAML

cat > /tmp/cnp.yaml <<'YAML'
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: deny-crypto-mining
  namespace: demo
spec:
  endpointSelector:
    matchLabels:
      app: attacker
  egress:
    - toEndpoints:
        - matchLabels:
            "k8s:io.kubernetes.pod.namespace": kube-system
            "k8s:k8s-app": kube-dns
      toPorts:
        - ports: [{ port: "53", protocol: ANY }]
          rules:
            dns:
              - matchPattern: "*.svc.cluster.local"
              - matchPattern: "*.debian.org"
    - toFQDNs:
        - matchPattern: "*.debian.org"
      toPorts:
        - ports: [{ port: "80", protocol: TCP }, { port: "443", protocol: TCP }]
    - toEntities: [cluster]
YAML

sec "Preparation"
K -n demo delete pod attacker --ignore-not-found >/dev/null 2>&1
if K apply -f /tmp/attacker.yaml >/dev/null 2>&1 && K -n demo wait --for=condition=Ready pod/attacker --timeout=90s >/dev/null 2>&1; then
  ok "pod attacker Ready"
  K apply -f /tmp/cnp.yaml >/dev/null 2>&1
  sleep 20
  sec "Verification"
  K -n demo exec attacker -- wget -q -T 8 -O /dev/null http://deb.debian.org/ 2>/dev/null && ok "deb.debian.org joignable" || wn "deb.debian.org injoignable"
  K -n demo exec attacker -- wget -q -T 8 -O /dev/null http://crypto-mining.pool/ 2>/dev/null && ko "crypto-mining.pool JOIGNABLE" || ok "crypto-mining.pool BLOQUE"
else
  ko "pod attacker non cree"
fi

K -n demo delete pod attacker --ignore-not-found >/dev/null 2>&1
K -n demo delete ciliumnetworkpolicy deny-crypto-mining --ignore-not-found >/dev/null 2>&1
rm -f /tmp/attacker.yaml /tmp/cnp.yaml
printf "\n  PASS=%d  FAIL=%d  WARN=%d\n\n" "$PASS" "$FAIL" "$WARN"
if [ "$FAIL" -eq 0 ]; then exit 0; else exit 1; fi
