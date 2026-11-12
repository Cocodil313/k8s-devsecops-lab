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
sec "Configuration"
AFF=$(K -n demo get deploy demo-app -o jsonpath="{.spec.template.spec.affinity.podAntiAffinity}" 2>/dev/null)
[ -z "$AFF" ] && ok "aucun podAntiAffinity" || ko "podAntiAffinity present"
MIN=$(K -n demo get hpa demo-app -o jsonpath="{.spec.minReplicas}" 2>/dev/null)
MAX=$(K -n demo get hpa demo-app -o jsonpath="{.spec.maxReplicas}" 2>/dev/null)
ok "bornes min=$MIN max=$MAX"

cat > /tmp/load.yaml <<'LOAD'
apiVersion: v1
kind: Pod
metadata:
  name: load-generator
  namespace: demo
  labels: { app: load-generator }
spec:
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    runAsGroup: 1000
    seccompProfile: { type: RuntimeDefault }
  containers:
    - name: load
      image: busybox:1.36
      command:
        - sh
        - -c
        - |
          while true; do
            for i in $(seq 1 500); do
              wget -q -O /dev/null http://demo-app.demo.svc.cluster.local/ &
            done
            wait
          done
      resources:
        requests: { cpu: 300m, memory: 64Mi }
        limits:   { cpu: 800m, memory: 256Mi }
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities: { drop: ["ALL"] }
      volumeMounts:
        - { name: tmp, mountPath: /tmp }
  volumes:
    - { name: tmp, emptyDir: {} }
LOAD

K -n demo delete pod load-generator --ignore-not-found >/dev/null 2>&1
AVANT=$(K -n demo get deploy demo-app -o jsonpath="{.spec.replicas}" 2>/dev/null)
sec "Scale-up (avant=$AVANT)"
if K apply -f /tmp/load.yaml >/dev/null 2>&1 && K -n demo wait --for=condition=Ready pod/load-generator --timeout=60s >/dev/null 2>&1; then
  PIC=${AVANT:-2}
  for i in $(seq 1 40); do
    DEP=$(K -n demo get deploy demo-app -o jsonpath="{.spec.replicas}" 2>/dev/null || echo 0)
    [ "${DEP:-0}" -gt "$PIC" ] && PIC=$DEP
    printf "  t=%3ss  replicas=%s\n" "$((i*5))" "${DEP:-0}"
    [ "${DEP:-0}" -gt "${AVANT:-2}" ] && break
    sleep 5
  done
  [ "${PIC:-0}" -gt "${AVANT:-2}" ] && ok "scale-up $AVANT -> $PIC" || ko "scale-up non observe"

  sec "Scale-down"
  K -n demo delete pod load-generator --ignore-not-found --wait=false >/dev/null 2>&1
  RET=""
  for i in $(seq 1 30); do
    DEP=$(K -n demo get deploy demo-app -o jsonpath="{.spec.replicas}" 2>/dev/null || echo 0)
    printf "  t=%3ss  replicas=%s\n" "$((i*10))" "${DEP:-0}"
    [ "${DEP:-99}" -le "${MIN:-2}" ] && RET="ok" && break
    sleep 10
  done
  [ "$RET" = "ok" ] && ok "scale-down retour a ${MIN:-2}" || ko "scale-down non termine"
else
  ko "load-generator non cree"
fi

K -n demo delete pod load-generator --ignore-not-found >/dev/null 2>&1
rm -f /tmp/load.yaml
printf "\n  PASS=%d  FAIL=%d  WARN=%d\n\n" "$PASS" "$FAIL" "$WARN"
if [ "$FAIL" -eq 0 ]; then exit 0; else exit 1; fi
