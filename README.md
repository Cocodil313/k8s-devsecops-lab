# k8s-devsecops-lab

Cluster Kubernetes durci, GitOps et observe, sur 3 VM Debian 13.
Hote Windows 16 Go, rien d installe cote hote hormis VirtualBox et Vagrant.

---

## Sommaire

- [Ce que deploie ce lab](#ce-que-deploie-ce-lab)
- [Architecture](#architecture)
- [Prerequis](#prerequis)
- [Deploiement](#deploiement)
- [Acces](#acces)
- [Tests](#tests)
- [Structure du depot](#structure-du-depot)
- [Versionne ou genere](#versionne-ou-genere)
- [Limites assumees](#limites-assumees)
- [Depannage](#depannage)
- [Detruire et reconstruire](#detruire-et-reconstruire)

---

## Ce que deploie ce lab

| Couche | Outil | Role |
|---|---|---|
| Orchestration | K3s v1.37 | cluster certifie, 3 noeuds |
| Reseau | Cilium 1.20 eBPF | CNI, kube-proxy remplace, policies L7 |
| GitOps | Argo CD | deploiement depuis Git (mode pull) |
| Admission | Kyverno v1.20 | bloque les manifests non conformes |
| Runtime | Falco 0.45 | detection syscalls (eBPF) |
| Secrets | Sealed Secrets | secrets chiffres, versionnes |
| Metriques | VictoriaMetrics | PromQL, remplace Prometheus |
| Dashboards | Grafana | datasource et dashboard provisionnes |
| CI | GitHub Actions | Gitleaks, Trivy, GHCR |

Empreinte : ~2,1 Go sur worker-1, ~700 Mo sur worker-2, ~900 Mo sur le master.
Sur 3 Go par VM, la marge est confortable.

---

## Architecture

| Nom | IP | RAM | Role | Label | Taint |
|---|---|---|---|---|---|
| k8s-master | 192.168.56.10 | 3 Go | control plane + bastion Ansible | — | NoSchedule |
| k8s-worker-1 | 192.168.56.11 | 3 Go | infrastructure | role=infra | aucun |
| k8s-worker-2 | 192.168.56.12 | 3 Go | applicatif | role=app | aucun |

**Placement** : les DaemonSets (Cilium, Falco, node-exporter) tournent sur les
3 noeuds, y compris le master, car ils doivent couvrir toutes les machines.
Les charges d infrastructure sont epinglees sur worker-1 par nodeSelector.
L application est repartie par topologySpreadConstraints.

**Reseau** : deux cartes par VM. eth0 en NAT pour la sortie Internet, eth1 en
host-only avec IP fixe pour tout le trafic cluster. K3s exige une URL de
serveur stable, l IP NAT change a chaque demarrage.

---

## Prerequis

| Requis | Version | Verification |
|---|---|---|
| Windows | 10 ou 11 | — |
| VirtualBox | >= 7.0 | VBoxManage --version |
| Vagrant | >= 2.4 | vagrant --version |
| Git | quelconque | git --version |
| RAM libre | 12 Go | — |
| Disque libre | 25 Go | — |

VirtualBox 7.0 minimum : le lab utilise nat-localhostreachable1.

Hyper-V et WSL2 doivent etre desactives (conflit VT-x) :

    bcdedit /enum | Select-String hypervisorlaunchtype
    # si "Auto" ou "On" :
    bcdedit /set hypervisorlaunchtype off
    # puis redemarrer Windows

Ports a verifier libres :

    netstat -ano | findstr ":8080 :3000 :8428 :30080 :6443 :2222 :2200 :2201"

---

## Deploiement

### 1. Cloner

    git clone https://github.com/Cocodil313/k8s-devsecops-lab.git
    cd k8s-devsecops-lab

### 2. Creer les 3 VM

    vagrant box add bento/debian-13 --provider=virtualbox
    vagrant validate
    vagrant up k8s-master
    vagrant up k8s-worker-1
    vagrant up k8s-worker-2

Duree : 10 a 15 min. Une VM a la fois pour identifier tout blocage de boot.

La paire de cles SSH du labo est generee automatiquement dans keys/ au premier
up. Rien a faire manuellement.

Verification :

    vagrant status
    vagrant ssh k8s-master -c "free -m | head -2; swapon --show; stat -fc %T /sys/fs/cgroup"

Attendu : 3 VM running, ~2900 Mo de RAM, aucune ligne de swap, cgroup2fs.

### 3. Installer Ansible sur le master

    vagrant ssh k8s-master -c "sudo apt-get install -y ansible"
    vagrant upload ansible /home/vagrant/ansible k8s-master
    vagrant upload scripts /home/vagrant/scripts k8s-master

Seule etape manuelle du labo : Ansible ne peut pas s installer lui-meme sur
une machine vierge.

### 4. Deployer le cluster

    vagrant ssh k8s-master
    cd ~/ansible

Puis, dans cet ordre :

    ansible all -m ping
    ansible-playbook playbooks/01-prereqs.yml
    ansible-playbook playbooks/02-k3s-server.yml
    ansible-playbook playbooks/03-k3s-agents.yml
    ansible-playbook playbooks/04-bastion.yml
    ansible-playbook playbooks/05-cilium.yml
    ansible-playbook playbooks/06-argocd.yml
    ansible-playbook playbooks/07-sealed-secrets.yml
    ansible-playbook playbooks/08-kyverno.yml
    ansible-playbook playbooks/09-observability.yml
    ansible-playbook playbooks/10-falco.yml
    ansible-playbook playbooks/11-motd.yml

Duree totale : ~15 min.

| Apres | Attendu |
|---|---|
| ping | 3 x SUCCESS |
| 01-prereqs | failed=0 sur les 3 noeuds |
| 02-k3s-server | k3s active, /readyz ok |
| 03-k3s-agents | 3 noeuds enregistres, tous NotReady |
| 04-bastion | 6 binaires dans /usr/local/bin |
| 05-cilium | 3 noeuds Ready, kube-proxy = 0 |
| 06-argocd | tunnel pf-argocd actif sur 8080 |
| 07-sealed-secrets | cle sauvegardee dans ~/backups |
| 08-kyverno | 2 ValidatingPolicy READY |
| 09-observability | series=4 |
| 10-falco | 3 pods 2/2, sonde eBPF chargee |
| 11-motd | banniere a la connexion |

### 5. Brancher Argo CD

    vagrant upload gitops /home/vagrant/gitops k8s-master
    vagrant ssh k8s-master -c "kubectl apply -f /home/vagrant/gitops/bootstrap/root-app.yaml"

Seul kubectl apply manuel du labo. Argo CD lit ensuite le depot toutes les
3 minutes.

    vagrant ssh k8s-master -c "sleep 45; kubectl -n argocd get applications"

Attendu : root et demo-app en Synced / Healthy.

### 6. Verifier

    vagrant ssh k8s-master -c "kubectl get nodes"
    vagrant ssh k8s-master -c "kubectl -n demo get pods -o wide"
    vagrant ssh k8s-master -c "kubectl -n demo get hpa"

---

## Acces

| URL | Service | Identifiants |
|---|---|---|
| http://localhost:8080 | Argo CD | admin + mot de passe ci-dessous |
| http://localhost:3000 | Grafana | admin / labadmin |
| http://localhost:8428/vmui | VictoriaMetrics | — |
| http://localhost:30080 | demo-app | — |

Mot de passe Argo CD :

    vagrant ssh k8s-master -c "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo"

localhost:30080 reste le meme lien en permanence. Le NAT pointe sur le master,
qui ne porte aucun pod applicatif : Cilium sert le NodePort sur tous les noeuds
et route vers les pods vivants. Une bascule de quelques secondes pendant un
reschedule est normale.

Toutes les interfaces sont bindees sur 127.0.0.1 cote Windows : jamais
accessibles depuis le reseau local.

---

## Tests

Un script par test, dans scripts/. Chacun est autonome et renvoie 0 ou 1.

| Script | Ce qu il verifie |
|---|---|
| test-prereqs.sh | 3 noeuds Ready, CNI charge, DaemonSets complets |
| test-argocd.sh | Applications Synced / Healthy |
| test-demo-url.sh | http://localhost:30080 repond 200 |
| test-kyverno.sh | une image :latest est refusee |
| test-falco.sh | apt-get et faux xmrig declenchent une alerte |
| test-cilium-l7.sh | domaine autorise joignable, domaine interdit bloque |
| test-sealed-secrets.sh | un SealedSecret est dechiffre dans le cluster |
| test-ha.sh | l URL repond avant, pendant et apres un reschedule |
| test-hpa.sh | les replicas montent sous charge puis redescendent |
| test-gitleaks.sh | un secret est detecte par Gitleaks |
| test-trivy.sh | CVE CRITICAL detectees sur une image EOL |

Tout lancer :

    vagrant ssh k8s-master -c "chmod +x ~/scripts/*.sh; bash ~/scripts/run-all-tests.sh"

Sortie attendue : PASS : N  FAIL : 0.

Un test seul :

    vagrant ssh k8s-master -c "bash ~/scripts/test-kyverno.sh"

---

## Structure du depot

    .
    ├── Vagrantfile                  infrastructure (VM, reseau, ports, cle SSH)
    ├── README.md
    ├── .gitignore
    ├── ansible/
    │   ├── ansible.cfg
    │   ├── inventory/
    │   │   ├── hosts.ini            3 hotes, groupes master/infra/app
    │   │   ├── group_vars/all.yml   versions, IP du master, paquets
    │   │   └── host_vars/           node_role + lab_node_ip par noeud
    │   ├── playbooks/               00-ping -> 11-motd
    │   └── roles/                   11 roles
    ├── app/                         source applicative (Dockerfile + index.html)
    ├── gitops/
    │   ├── apps/demo/               namespace, deployment, service, hpa, kustomization
    │   ├── argocd/apps/             Application Argo CD
    │   └── bootstrap/               root-app (app-of-apps)
    ├── scripts/                     11 tests + run-all-tests.sh
    └── .github/workflows/ci.yaml    Gitleaks -> Trivy -> GHCR -> bump

---

## Versionne ou genere

| Element | Versionne | Genere par | Reconstructible |
|---|---|---|---|
| Vagrantfile, ansible/, gitops/, app/, scripts/, CI | oui | — | — |
| keys/lab_ed25519 | non | vagrant up | oui |
| .vagrant/ | non | Vagrant | oui |
| Cle Sealed Secrets | non | controleur | non |

La cle Sealed Secrets est le seul element non reproductible. Le playbook 07 la
sauvegarde dans /home/vagrant/backups/sealed-secrets-key.yaml. Copie-la hors de
Git :

    vagrant ssh k8s-master -c "cat ~/backups/sealed-secrets-key.yaml" | Out-File -Encoding utf8 sealed-secrets-key.BACKUP.yaml

---

## Limites assumees

| Limite | Raison |
|---|---|
| 1 seul master | 3 VM x 3 Go = 9 Go, un 2e master couterait 3 Go de plus |
| Cilium hors GitOps | il faut un CNI pour demarrer Argo CD |
| Pas d alerting | metriques et dashboards suffisent pour un labo |
| Versions non epinglees | choix de la phase d apprentissage |
| 2 repliques sur 2 workers | redondance applicative, pas de HA en cas de panne noeud |
| metrics-server patche a la main | K3s reinstalle ses addons au redemarrage |

---

## Depannage

**Une VM ne boote pas**

Ouvre la console VirtualBox (bouton Afficher). Prompt de login visible =
probleme reseau ou SSH, vagrant reload <vm>. Ecran fige = Hyper-V actif.

**localhost:8080 ne repond pas**

    vagrant ssh k8s-master -c "systemctl is-active pf-argocd; ss -tlnp | grep 8080"
    vagrant port k8s-master

**Noeuds NotReady apres Cilium**

    vagrant ssh k8s-master -c "sudo k3s crictl info | grep -E 'confDir|binDir'"

Attendu : /etc/cni/net.d et /opt/cni/bin.

**Pods Pending apres un scale-up**

    vagrant ssh k8s-master -c "kubectl -n demo get deploy demo-app -o jsonpath='{.spec.template.spec.affinity}'; echo"

Doit etre vide. Un podAntiAffinity plafonne le Deployment a 2 pods.

**Argo CD Unknown**

    vagrant ssh k8s-master -c "kubectl -n argocd get application demo-app -o jsonpath='{.status.conditions}'; echo"

Verifier que spec.source.path correspond a l arborescence du depot.

**Dashboard Grafana absent**

Le provider scanne son dossier au demarrage :

    vagrant ssh k8s-master -c "kubectl -n monitoring rollout restart deploy/grafana"

**Pods en erreur**

    kubectl -n demo get pods | grep -vE "Running|Completed"

Le dashboard Grafana contient 3 tables de diagnostic : pods en erreur avec
leur phase, conteneurs qui ne demarrent pas avec la raison, et redemarrages
sur 1h.

---

## Detruire et reconstruire

    vagrant destroy -f

Puis reprendre a l etape 2. Les 3 VM, K3s, Cilium, Argo CD, Kyverno, Sealed
Secrets, VictoriaMetrics, Grafana, Falco et l application sont reconstruits par
les playbooks.

Un destroy genere une nouvelle cle Sealed Secrets : les anciens *.sealed.yaml
deviennent indechiffrables. Restaurer le backup avant de rejouer
07-sealed-secrets.

Test de reproductibilite :

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    vagrant destroy -f
    vagrant up --no-parallel
    # puis les 12 playbooks
    $sw.Stop()
    "$([int]$sw.Elapsed.TotalMinutes) min"