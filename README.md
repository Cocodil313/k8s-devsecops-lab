# Lab DevSecOps Kubernetes

Cluster K3s durci, GitOps et observe, sur 3 VM Debian 13.
Hote Windows, rien d installe cote hote hormis VirtualBox et Vagrant.

Cilium eBPF - Argo CD - Kyverno - Falco - Sealed Secrets - VictoriaMetrics - Grafana - GitHub Actions

---

## Sommaire

1. [IMPORTANT - Personnaliser avant de pousser](#important---personnaliser-avant-de-pousser)
2. [Ce que tu obtiens](#ce-que-tu-obtiens)
3. [Architecture](#architecture)
4. [Prerequis](#prerequis)
5. [Deploiement](#deploiement)
6. [Acces](#acces)
7. [Tests](#tests)
8. [Structure du depot](#structure-du-depot)
9. [Versionne ou genere](#versionne-ou-genere)
10. [Limites assumees](#limites-assumees)
11. [Depannage](#depannage)
12. [Detruire et reconstruire](#detruire-et-reconstruire)

---

## IMPORTANT - Personnaliser avant de pousser

**Lis cette section en premier.** Ton compte GitHub apparait a 3 endroits. Si tu ne les changes pas, le pipeline echoue et Argo CD reste en erreur.

### Les 3 fichiers a editer

| # | Fichier | Ligne a modifier | Valeur attendue |
|---|---|---|---|
| 1 | gitops/bootstrap/root-app.yaml | repoURL: | https://github.com/USER/REPO.git |
| 2 | gitops/argocd/apps/demo-app.yaml | repoURL: | https://github.com/USER/REPO.git |
| 3 | .github/workflows/ci.yaml | IMAGE: | ghcr.io/USER/REPO |

Commandes d edition :

    notepad gitops\bootstrap\root-app.yaml
    notepad gitops\argocd\apps\demo-app.yaml
    notepad .github\workflows\ci.yaml

**Ce qui casse si tu oublies :**

| Fichier oublie | Erreur observee |
|---|---|
| root-app.yaml | Argo CD : repository not found, ou app path does not exist |
| demo-app.yaml | demo-app reste Unknown, le namespace demo n est jamais cree |
| ci.yaml | pipeline rouge au docker push : denied: permission_denied |

**GHCR refuse les majuscules.** Cocodil313 doit s ecrire cocodil313 dans IMAGE. L erreur n apparait qu au moment du push, pas avant.

### Verifier les 3 lignes en une commande

    Select-String -Path .\gitops\bootstrap\root-app.yaml,.\gitops\argocd\apps\demo-app.yaml -Pattern "repoURL"
    Select-String -Path .\.github\workflows\ci.yaml -Pattern "IMAGE:"

### Le remote Git

    git remote set-url origin https://github.com/USER/REPO.git

### Premier push - l ordre compte

    git config --global user.name  "USER"
    git config --global user.email "USER@users.noreply.github.com"

    git add -A
    git commit -m "init: lab devsecops"
    git branch -M main
    git push -u origin main

git branch -M main doit passer APRES le premier commit. Avant, il echoue silencieusement et le push renvoie : src refspec main does not match any.

### Configuration GitHub obligatoire (une seule fois)

| Etape | URL | Action |
|---|---|---|
| 1 | https://github.com/USER/REPO/settings/actions | Workflow permissions -> Read and write -> Save |
| 2 | https://github.com/USER?tab=packages | package -> Package settings -> Change visibility -> Public |

Le package n apparait a l etape 2 qu apres le premier pipeline reussi. Lance un git push sur app/ d abord.

### Verifier qu il ne reste aucune trace de l ancien compte

    Select-String -Path .\**\*.yaml,.\**\*.yml -Pattern "Cocodil313" -ErrorAction SilentlyContinue

Aucun resultat attendu.

---
## Ce que tu obtiens

| Couche | Outil | Role | RAM |
|---|---|---|---|
| Orchestration | K3s v1.37 | cluster certifie, 3 noeuds | ~550 Mo |
| Reseau | Cilium 1.20 eBPF | CNI, kube-proxy remplace, policies L7 | ~130 Mo/noeud |
| GitOps | Argo CD | deploiement depuis Git, mode pull | ~700 Mo |
| Admission | Kyverno v1.20 | bloque les manifests non conformes | ~400 Mo |
| Runtime | Falco 0.45 | detection syscalls via eBPF | ~130 Mo/noeud |
| Secrets | Sealed Secrets | secrets chiffres, versionnables | ~30 Mo |
| Metriques | VictoriaMetrics | PromQL, remplace Prometheus | ~150 Mo |
| Dashboards | Grafana | datasource et dashboard provisionnes | ~130 Mo |
| CI | GitHub Actions | Gitleaks, Trivy, GHCR | 0 Mo en local |

Total : ~2,1 Go sur worker-1, ~700 Mo sur worker-2, ~900 Mo sur le master. Sur 3 Go par VM, la marge est confortable.

---

## Architecture

| Nom | IP | RAM | Role | Label | Taint |
|---|---|---|---|---|---|
| k8s-master | 192.168.56.10 | 3 Go | control plane + bastion Ansible | - | NoSchedule |
| k8s-worker-1 | 192.168.56.11 | 3 Go | infrastructure | role=infra | aucun |
| k8s-worker-2 | 192.168.56.12 | 3 Go | applicatif | role=app | aucun |

### Placement des charges

| Noeud | Ce qui y tourne | Mecanisme |
|---|---|---|
| master | DaemonSets uniquement (Cilium, Falco, node-exporter) + CoreDNS | taint NoSchedule |
| worker-1 | Argo CD, Kyverno, VictoriaMetrics, Grafana, Sealed Secrets | nodeSelector role=infra |
| worker-2 | demo-app | topologySpreadConstraints |

Les DaemonSets tolerent le taint : ils doivent couvrir tous les noeuds, y compris le control plane. C est une exception volontaire.

### Reseau

Deux cartes par VM, deux roles separes :

| Interface | Type | Usage |
|---|---|---|
| eth0 | NAT VirtualBox | sortie Internet : apt, pulls d images, GitHub |
| eth1 | Host-only, IP fixe | tout le trafic cluster : API 6443, kubelet 10250, VXLAN 8472 |

K3s exige une URL de serveur stable. L IP NAT change a chaque demarrage, elle est donc inutilisable pour le cluster.

---

## Prerequis

| Requis | Version | Verification |
|---|---|---|
| Windows | 10 ou 11 | - |
| VirtualBox | 7.0 minimum | VBoxManage --version |
| Vagrant | 2.4 minimum | vagrant --version |
| Git | quelconque | git --version |
| RAM libre | 12 Go | - |
| Disque libre | 25 Go | - |

VirtualBox 7.0 minimum : le lab utilise nat-localhostreachable1, absent des versions precedentes.

### Hyper-V et WSL2 desactives

VirtualBox a besoin de VT-x, que Hyper-V monopolise.

    bcdedit /enum | Select-String hypervisorlaunchtype
    # si "Auto" ou "On" :
    bcdedit /set hypervisorlaunchtype off
    # puis REDEMARRER Windows

### Ports libres

    netstat -ano | findstr ":8080 :3000 :8428 :30080 :6443 :2222 :2200 :2201"

Aucun resultat attendu. Si un port est pris, le up echoue volontairement (auto_correct: false) plutot que de decaler silencieusement l URL.

---
## Deploiement

### 1. Cloner et personnaliser

    git clone https://github.com/USER/REPO.git
    cd REPO

Puis applique la section IMPORTANT ci-dessus : 3 fichiers, 3 lignes.

### 2. Creer les 3 VM

    vagrant box add bento/debian-13 --provider=virtualbox
    vagrant validate
    vagrant up k8s-master
    vagrant up k8s-worker-1
    vagrant up k8s-worker-2

Duree : 10 a 15 min. Une VM a la fois pour identifier tout blocage de boot.

La paire de cles SSH du labo est generee automatiquement dans keys/ au premier up. Rien a faire manuellement.

**Controle**

    vagrant status
    vagrant ssh k8s-master -c "free -m | head -2; swapon --show; stat -fc %T /sys/fs/cgroup"

Attendu : 3 VM running, ~2900 Mo de RAM, aucune ligne de swap, cgroup2fs.

Si une VM ne boote pas, ouvre la console VirtualBox (bouton Afficher) et regarde l ecran.

### 3. Installer Ansible

    vagrant ssh k8s-master -c "sudo apt-get install -y ansible"
    vagrant upload ansible /home/vagrant/ansible k8s-master
    vagrant upload scripts /home/vagrant/scripts k8s-master

**Seule action manuelle du labo** : Ansible ne peut pas s installer lui-meme sur une machine vierge.

**Controle**

    vagrant ssh k8s-master -c "ansible --version | head -1; ls ~/ansible/playbooks | wc -l"

Attendu : core 2.x, puis 12.

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

**Points de controle** - si un playbook echoue, arrete-toi la :

| Apres | Verification | Attendu |
|---|---|---|
| ping | - | 3 x SUCCESS |
| 02 | k3s kubectl get nodes | 1 noeud NotReady |
| 03 | k3s kubectl get nodes | 3 noeuds NotReady |
| 05 | k3s kubectl get nodes | 3 noeuds Ready |
| 06 | systemctl is-active pf-argocd | active |
| 07 | ls -l ~/backups/ | cle > 1 Ko |
| 08 | kubectl get validatingpolicy | 2 policies READY |
| 09 | rapport final | series=4 |
| 10 | kubectl -n falco get pods | 3 pods 2/2 |
| 11 | reconnexion SSH | banniere affichee |

NotReady apres l etape 3 est **normal** : Cilium n est pas encore installe.

### 5. Brancher Argo CD

    vagrant upload gitops /home/vagrant/gitops k8s-master
    vagrant ssh k8s-master -c "kubectl apply -f /home/vagrant/gitops/bootstrap/root-app.yaml"

**Seul kubectl apply manuel du labo.** Argo CD lit ensuite le depot toutes les 3 minutes.

**Controle**

    vagrant ssh k8s-master -c "sleep 45; kubectl -n argocd get applications"

Attendu : root et demo-app en Synced / Healthy.

Si Unknown persiste, force un re-fetch :

    vagrant ssh k8s-master -c "kubectl -n argocd annotate application root argocd.argoproj.io/refresh=hard --overwrite"
    vagrant ssh k8s-master -c "kubectl -n argocd annotate application demo-app argocd.argoproj.io/refresh=hard --overwrite"

### 6. Verifier

    vagrant ssh k8s-master -c "bash ~/scripts/run-all-tests.sh"

Attendu : OK : 11   KO : 0.

---
## Acces

| URL | Service | Identifiants |
|---|---|---|
| http://localhost:8080 | Argo CD | admin + mot de passe ci-dessous |
| http://localhost:3000 | Grafana | admin / labadmin |
| http://localhost:8428/vmui | VictoriaMetrics | - |
| http://localhost:30080 | demo-app | - |

Mot de passe Argo CD :

    vagrant ssh k8s-master -c "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath={.data.password} | base64 -d; echo"

### Pourquoi localhost:30080 ne change jamais

    localhost:30080  ->  NAT VirtualBox  ->  k8s-master:30080
                                                |
                                        Cilium NodePort
                                                |
                                  pods vivants (worker-1 / worker-2)

Le master ne porte aucun pod applicatif : il sert de point d entree stable. Cilium route vers les pods vivants, quel que soit le worker qui les heberge. Une bascule de quelques secondes pendant un reschedule est normale.

Toutes les interfaces sont bindees sur 127.0.0.1 cote Windows : **jamais accessibles depuis le reseau local**.

---

## Tests

Un script par test, dans scripts/. Chacun est autonome, renvoie 0 ou 1, et affiche PASS / FAIL / WARN.

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

**Tout lancer**

    vagrant ssh k8s-master -c "chmod +x ~/scripts/*.sh; bash ~/scripts/run-all-tests.sh"

**Un seul test**

    vagrant ssh k8s-master -c "bash ~/scripts/test-kyverno.sh"

---

## Structure du depot

    .
    |-- Vagrantfile                  infrastructure (VM, reseau, ports, cle SSH)
    |-- README.md
    |-- .gitignore
    |
    |-- ansible/                     12 playbooks, 11 roles
    |   |-- ansible.cfg
    |   |-- inventory/
    |   |   |-- hosts.ini            3 hotes, groupes master / infra / app
    |   |   |-- group_vars/all.yml   channel K3s, IP du master, paquets
    |   |   +-- host_vars/           node_role + lab_node_ip par noeud
    |   |-- playbooks/               00-ping -> 11-motd
    |   +-- roles/                   k8s_prereqs, k3s_server, k3s_agent,
    |                                bastion, cilium, argocd, sealed_secrets,
    |                                kyverno, observability, falco, motd
    |
    |-- app/                         source applicative
    |   |-- Dockerfile
    |   |-- index.html
    |   +-- .dockerignore
    |
    |-- gitops/                      source de verite lue par Argo CD
    |   |-- apps/demo/               namespace, deployment, service, hpa, kustomization
    |   |-- argocd/apps/             Application Argo CD        <- repoURL a changer
    |   +-- bootstrap/               root-app (app-of-apps)     <- repoURL a changer
    |
    |-- scripts/                     11 tests + run-all-tests.sh
    |
    +-- .github/workflows/ci.yaml    Gitleaks -> Trivy -> GHCR  <- IMAGE a changer

**3 fichiers a la racine**, 5 dossiers, ~76 fichiers versionnes.

---

## Versionne ou genere

| Element | Versionne | Genere par | Reconstructible |
|---|---|---|---|
| Vagrantfile, ansible/, gitops/, app/, scripts/, CI | oui | - | - |
| keys/lab_ed25519 | non | vagrant up | oui |
| .vagrant/ | non | Vagrant | oui |
| Cle Sealed Secrets | non | controleur | NON |

### La cle Sealed Secrets

C est le **seul element non reproductible** du labo. Le playbook 07 la sauvegarde dans /home/vagrant/backups/sealed-secrets-key.yaml. Copie-la hors de Git :

    vagrant ssh k8s-master -c "cat ~/backups/sealed-secrets-key.yaml" | Out-File -Encoding utf8 sealed-secrets-key.BACKUP.yaml

Sans elle, un vagrant destroy rend tous les *.sealed.yaml du depot definitivement indechiffrables.

---
## Limites assumees

| Limite | Raison |
|---|---|
| 1 seul master | 3 VM x 3 Go = 9 Go. Un 2e master couterait 3 Go de plus |
| Cilium hors GitOps | il faut un CNI pour demarrer Argo CD |
| Pas d alerting | metriques et dashboards suffisent pour un labo |
| Versions non epinglees | choix de la phase d apprentissage |
| 2 replicas sur 2 workers | redondance applicative, pas de HA en cas de panne noeud |
| metrics-server patche a la main | K3s reinstalle ses addons au redemarrage |

---

## Depannage

### Une VM ne boote pas

Ouvre la console VirtualBox (bouton Afficher).

| Ce que tu vois | Cause | Correctif |
|---|---|---|
| Prompt de login | la VM boote, probleme reseau/SSH | vagrant reload VM |
| Ecran fige, logo Debian | Hyper-V actif | bcdedit /set hypervisorlaunchtype off + redemarrage |
| VT-x is not available | Hyper-V ou WSL2 | idem |
| Ecran noir | VM en etat incoherent | vagrant destroy -f puis vagrant up |

### localhost:8080 ne repond pas

    vagrant ssh k8s-master -c "systemctl is-active pf-argocd; ss -tlnp | grep 8080"
    vagrant port k8s-master

### Noeuds NotReady apres Cilium

    vagrant ssh k8s-master -c "sudo k3s crictl info | grep -E confDir"

Attendu : /etc/cni/net.d et /opt/cni/bin.

### Pods Pending apres un scale-up

    vagrant ssh k8s-master -c "kubectl -n demo get deploy demo-app -o jsonpath={.spec.template.spec.affinity}; echo"

Doit etre vide. Un podAntiAffinity plafonne le Deployment a 2 pods.

### Argo CD en Unknown

    vagrant ssh k8s-master -c "kubectl -n argocd get application demo-app -o jsonpath={.status.conditions}; echo"

| Message | Cause |
|---|---|
| repository not found | repoURL errone ou depot prive |
| app path does not exist | le chemin gitops/apps/demo n existe pas dans le commit pousse |
| ComparisonError sans detail | cache repo-server : kubectl -n argocd rollout restart deploy/argocd-repo-server |

### Dashboard Grafana absent

Le provider scanne son dossier **au demarrage** :

    vagrant ssh k8s-master -c "kubectl -n monitoring rollout restart deploy/grafana"

### Voir les pods en erreur

    vagrant ssh k8s-master -c "kubectl get pods -A | grep -vE Running"

Le dashboard Grafana contient 3 tables de diagnostic : pods en erreur avec leur phase, conteneurs qui ne demarrent pas avec la raison, et redemarrages sur 1 h.

---

## Detruire et reconstruire

    vagrant destroy -f

Puis reprendre a l **etape 2**. Les 3 VM, K3s, Cilium, Argo CD, Kyverno, Sealed Secrets, VictoriaMetrics, Grafana, Falco et l application sont reconstruits par les playbooks.

Un destroy genere une **nouvelle** cle Sealed Secrets. Restaure le backup avant de rejouer 07-sealed-secrets.

### Test de reproductibilite

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    vagrant destroy -f
    vagrant up --no-parallel
    # puis les 12 playbooks
    $sw.Stop()
    "$([int]$sw.Elapsed.TotalMinutes) min"

Objectif : moins de 30 minutes, sans intervention manuelle autre que l installation d Ansible.
