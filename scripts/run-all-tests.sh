#!/usr/bin/env bash
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
C_G='\033[32m'; C_R='\033[31m'; C_Y='\033[33m'; C_C='\033[36m'; C_0='\033[0m'

TESTS=(
  test-prereqs.sh
  test-argocd.sh
  test-demo-url.sh
  test-kyverno.sh
  test-falco.sh
  test-cilium-l7.sh
  test-sealed-secrets.sh
  test-ha.sh
  test-hpa.sh
  test-gitleaks.sh
  test-trivy.sh
)

printf "\n${C_C}#############################################################${C_0}\n"
printf "${C_C}#  SUITE COMPLETE DE TESTS - LAB DEVSECOPS K8S             #${C_0}\n"
printf "${C_C}#############################################################${C_0}\n"
printf "  Date : %s\n" "$(date -Is)"

TOTAL_OK=0
TOTAL_KO=0
RESULTS=""

for t in "${TESTS[@]}"; do
  if [ ! -f "$DIR/$t" ]; then
    RESULTS="$RESULTS
  SKIP  $t"
    continue
  fi
  printf "\n${C_C}-------------------------------------------------------------${C_0}\n"
  printf "${C_C}>>> %s${C_0}\n" "$t"
  if bash "$DIR/$t"; then
    RESULTS="$RESULTS
  ${C_G}OK  ${C_0}  $t"
    TOTAL_OK=$((TOTAL_OK+1))
  else
    RESULTS="$RESULTS
  ${C_R}KO  ${C_0}  $t"
    TOTAL_KO=$((TOTAL_KO+1))
  fi
done

printf "\n${C_C}=============================================================${C_0}\n"
printf "${C_C}#  RESUME                                                   #${C_0}\n"
printf "${C_C}=============================================================${C_0}\n"
printf "%b\n" "$RESULTS"
printf "\n  ${C_G}OK : %d${C_0}   ${C_R}KO : %d${C_0}\n\n" "$TOTAL_OK" "$TOTAL_KO"
if [ "$TOTAL_KO" -eq 0 ]; then exit 0; else exit 1; fi