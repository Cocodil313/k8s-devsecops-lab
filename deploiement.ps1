$ErrorActionPreference = 'Stop'
$U = New-Object System.Text.UTF8Encoding($false)
$R = (Get-Location).Path
Write-Host "Creation dans : $R`n" -ForegroundColor Cyan
$n = 0
function W([string]$rel, [string]$content) {
    $p = Join-Path $R $rel
    $d = Split-Path -Parent $p
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    [System.IO.File]::WriteAllText($p, ($content -replace "`r`n","`n"), $U)
    $script:n++
    Write-Host ("  [OK] " + $rel) -ForegroundColor Green
}

# ══════════════════════════════════════════════════════════════════════════
# RACINE
# ══════════════════════════════════════════════════════════════════════════

W 'Vagrantfile' @'
# -*- mode: ruby -*-
# vi: set ft=ruby :
# Lab DevSecOps Kubernetes — infrastructure uniquement.
# Ce fichier ne fait que les VM, le reseau, les ports et la cle SSH.
require 'fileutils'

BOX         = "bento/debian-13"
BOX_VERSION = nil
CPUS        = 2
MEMORY      = 3072
DOMAIN      = "lab.local"
GUI         = true

NODES = [
  { name: "k8s-master",   ip: "192.168.56.10", role: "master" },
  { name: "k8s-worker-1", ip: "192.168.56.11", role: "infra"  },
  { name: "k8s-worker-2", ip: "192.168.56.12", role: "app"    },
]

# host_ip 127.0.0.1 : les interfaces ne sont jamais exposees au reseau local.
# 30080 est publie sur le master : Cilium sert le NodePort sur tous les
# noeuds, et le master ne porte aucun pod applicatif. L URL reste stable.
PUBLISHED = {
  "k8s-master"   => [
    { host: 8080,  guest: 8080,  id: "argocd"   },
    { host: 3000,  guest: 3000,  id: "grafana"  },
    { host: 8428,  guest: 8428,  id: "vmui"     },
    { host: 30080, guest: 30080, id: "demo-app" },
    { host: 6443,  guest: 6443,  id: "k3s-api"  },
    { host: 2222,  guest: 22,    id: "ssh"      },
  ],
  "k8s-worker-1" => [{ host: 2200, guest: 22, id: "ssh" }],
  "k8s-worker-2" => [{ host: 2201, guest: 22, id: "ssh" }],
}

KEY_DIR  = File.join(__dir__, "keys")
PRIV_KEY = File.join(KEY_DIR, "lab_ed25519")
FileUtils.mkdir_p(KEY_DIR)
unless File.exist?(PRIV_KEY)
  system("ssh-keygen", "-t", "ed25519", "-N", "", "-C", "lab@devsecops",
         "-f", PRIV_KEY, out: File::NULL, err: File::NULL)
  abort("ssh-keygen a echoue : verifier le PATH") unless File.exist?(PRIV_KEY + ".pub")
  puts "[lab] paire de cles generee : #{PRIV_KEY}"
end

Vagrant.configure("2") do |config|
  config.vm.box_check_update = false
  config.vm.boot_timeout     = 300
  config.vm.synced_folder ".", "/vagrant", disabled: true

  NODES.each do |node|
    config.vm.define node[:name] do |vm|
      vm.vm.hostname    = "#{node[:name]}.#{DOMAIN}"
      vm.vm.box         = BOX
      vm.vm.box_version = BOX_VERSION if BOX_VERSION
      vm.vm.network "private_network", ip: node[:ip], netmask: "255.255.255.0"

      PUBLISHED.fetch(node[:name], []).each do |p|
        vm.vm.network "forwarded_port", guest: p[:guest], host: p[:host],
                      host_ip: "127.0.0.1", id: p[:id], auto_correct: false
      end

      vm.vm.provider "virtualbox" do |vb|
        vb.name         = node[:name]
        vb.memory       = MEMORY
        vb.cpus         = CPUS
        vb.linked_clone = true
        vb.gui          = GUI
        # Obligatoire pour http://localhost:8080 : sans ce flag le NAT ignore
        # les connexions venant de la loopback de l hote (VirtualBox >= 7.0).
        vb.customize ["modifyvm", :id, "--nat-localhostreachable1", "on"]
        vb.customize ["modifyvm", :id, "--ioapic", "on"]
        vb.customize ["modifyvm", :id, "--rtcuseutc", "on"]
        vb.customize ["modifyvm", :id, "--audio", "none"]
        vb.customize ["modifyvm", :id, "--usb", "off"]
        vb.customize ["modifyvm", :id, "--graphicscontroller", "vboxsvga"]
        vb.customize ["modifyvm", :id, "--vram", "32"]
        vb.customize ["modifyvm", :id, "--accelerate3d", "off"]
      end

      vm.vm.provision "file", source: "keys/lab_ed25519.pub", destination: "/tmp/lab_key.pub"
      vm.vm.provision "shell", name: "ssh-pubkey", inline: <<~'SH'
        set -e
        install -d -m 0700 -o vagrant -g vagrant /home/vagrant/.ssh
        touch /home/vagrant/.ssh/authorized_keys
        grep -qF "$(cat /tmp/lab_key.pub)" /home/vagrant/.ssh/authorized_keys \
          || cat /tmp/lab_key.pub >> /home/vagrant/.ssh/authorized_keys
        chown vagrant:vagrant /home/vagrant/.ssh/authorized_keys
        chmod 0600 /home/vagrant/.ssh/authorized_keys
        rm -f /tmp/lab_key.pub
      SH

      if node[:role] == "master"
        vm.vm.provision "file", source: "keys/lab_ed25519", destination: "/tmp/lab_ed25519"
        vm.vm.provision "shell", name: "ssh-privkey", inline: <<~'SH'
          set -e
          install -m 0600 -o vagrant -g vagrant /tmp/lab_ed25519 /home/vagrant/.ssh/lab_ed25519
          rm -f /tmp/lab_ed25519
        SH
      end
    end
  end
end
'@

W '.gitignore' @'
.vagrant/
keys/
*.BACKUP.yaml
*.log
*.txt
*.bak
.DS_Store
'@

# ══════════════════════════════════════════════════════════════════════════
# ANSIBLE
# ══════════════════════════════════════════════════════════════════════════

W 'ansible/ansible.cfg' @'
# Chemins absolus : Ansible ne lit ansible.cfg que dans le repertoire courant,
# ~/.ansible.cfg et /etc/ansible/. En relatif, lancer un playbook depuis
# playbooks/ casse l inventaire et la resolution des roles.
[defaults]
inventory  = /home/vagrant/ansible/inventory/hosts.ini
roles_path = /home/vagrant/ansible/roles
host_key_checking = False
forks = 10
deprecation_warnings = False
retry_files_enabled = False

[ssh_connection]
# Envoie le module Python dans le meme canal SSH : divise par deux le nombre
# d allers-retours reseau.
pipelining = True
'@

W 'ansible/inventory/hosts.ini' @'
[master]
k8s-master ansible_host=192.168.56.10

[infra]
k8s-worker-1 ansible_host=192.168.56.11

[app]
k8s-worker-2 ansible_host=192.168.56.12

[workers:children]
infra
app

[k8s:children]
master
workers

[all:vars]
ansible_user=vagrant
ansible_ssh_private_key_file=/home/vagrant/.ssh/lab_ed25519
ansible_ssh_common_args=-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
'@

W 'ansible/inventory/group_vars/all.yml' @'
---
# "stable" suit la derniere release. Figer en "v1.37" pour une reproductibilite
# totale entre deux sessions.
k3s_channel: "stable"

# IP du control plane : utilisee par les agents K3s ET par Cilium
# (k8sServiceHost). Doit correspondre au tls-san du serveur.
lab_master_ip: "192.168.56.10"

lab_timezone: "Europe/Paris"

# Cache APT rafraichi au plus une fois par fenetre et par VM.
apt_cache_valid_time: 3600

k8s_base_packages:
  - curl
  - ca-certificates
  - jq
  - iproute2
  - vim
  - less
  - htop
'@

W 'ansible/inventory/host_vars/k8s-master.yml' @'
---
node_role: master
lab_node_ip: "192.168.56.10"
'@

W 'ansible/inventory/host_vars/k8s-worker-1.yml' @'
---
node_role: infra
lab_node_ip: "192.168.56.11"
'@

W 'ansible/inventory/host_vars/k8s-worker-2.yml' @'
---
node_role: app
lab_node_ip: "192.168.56.12"
'@

W 'ansible/playbooks/00-ping.yml' @'
---
- name: Ping des 3 noeuds
  hosts: k8s
  gather_facts: false
  tasks:
    - name: Ping
      ansible.builtin.ping:
'@

W 'ansible/playbooks/01-prereqs.yml' @'
---
- name: Prerequis K3s
  hosts: k8s
  become: true
  roles:
    - k8s_prereqs
'@

W 'ansible/playbooks/02-k3s-server.yml' @'
---
- name: Control plane K3s
  hosts: master
  become: true
  roles:
    - k3s_server
'@

W 'ansible/playbooks/03-k3s-agents.yml' @'
---
# Le token n est jamais dans le depot : K3s le genere sur le master,
# Ansible le lit avec slurp + no_log et l injecte dans la config des agents.
- name: Lire le token genere par le control plane
  hosts: master
  become: true
  gather_facts: false
  tasks:
    - name: Slurp du node-token
      ansible.builtin.slurp:
        src: /var/lib/rancher/k3s/server/node-token
      register: token_raw
      no_log: true
    - name: Exposer le token aux workers
      ansible.builtin.set_fact:
        k3s_token: "{{ token_raw.content | b64decode | trim }}"
      no_log: true

- name: Agents K3s
  hosts: workers
  become: true
  vars:
    k3s_token: "{{ hostvars['k8s-master'].k3s_token }}"
  roles:
    - k3s_agent
'@

W 'ansible/playbooks/04-bastion.yml' @'
---
- name: Bastion d administration
  hosts: master
  become: true
  roles:
    - bastion
'@

W 'ansible/playbooks/05-cilium.yml' @'
---
# Composant de bootstrap : Argo CD a besoin du reseau pour demarrer.
- name: Cilium
  hosts: master
  become: true
  roles:
    - cilium
'@

W 'ansible/playbooks/06-argocd.yml' @'
---
- name: Argo CD
  hosts: master
  become: true
  roles:
    - argocd
'@

W 'ansible/playbooks/07-sealed-secrets.yml' @'
---
- name: Sealed Secrets
  hosts: master
  become: true
  roles:
    - sealed_secrets
'@

W 'ansible/playbooks/08-kyverno.yml' @'
---
- name: Kyverno
  hosts: master
  become: true
  roles:
    - kyverno
'@

W 'ansible/playbooks/09-observability.yml' @'
---
- name: Observabilite
  hosts: master
  become: true
  roles:
    - observability
'@

W 'ansible/playbooks/10-falco.yml' @'
---
- name: Falco
  hosts: master
  become: true
  roles:
    - falco
'@

W 'ansible/playbooks/11-motd.yml' @'
---
- name: MOTD
  hosts: k8s
  become: true
  roles:
    - motd
'@

# ══════════════════════════════════════════════════════════════════════════
# ROLE k8s_prereqs
# ══════════════════════════════════════════════════════════════════════════

W 'ansible/roles/k8s_prereqs/handlers/main.yml' @'
---
- name: reload sysctl
  ansible.builtin.command: sysctl --system
  changed_when: false
'@

W 'ansible/roles/k8s_prereqs/tasks/main.yml' @'
---
# Le kubelet refuse de demarrer avec du swap actif : les requests/limits
# n auraient plus de sens si le noyau pouvait swapper un pod garanti.
- name: Desactiver le swap
  ansible.builtin.command: swapoff -a
  changed_when: false
  failed_when: false

- name: Commenter la ligne swap de fstab
  ansible.builtin.replace:
    path: /etc/fstab
    regexp: '^([^#].*\sswap\s.*)$'
    replace: '# \1'

# overlay : storage driver de containerd.
# br_netfilter : rend le trafic bridge visible d iptables (Services K8s).
# nf_conntrack et iptable_nat : prerequis eBPF de Cilium.
- name: Declarer les modules au boot
  ansible.builtin.copy:
    dest: /etc/modules-load.d/k8s.conf
    mode: "0644"
    content: |
      overlay
      br_netfilter
      nf_conntrack
      iptable_nat
      iptable_filter

- name: Charger les modules
  ansible.builtin.command: "modprobe {{ item }}"
  loop: [overlay, br_netfilter, nf_conntrack, iptable_nat, iptable_filter]
  changed_when: false
  failed_when: false

# ip_forward : routage Pod a Pod et Pod vers Internet.
# bridge-nf-call-iptables : iptables voit le trafic bridge.
# overcommit_memory : K3s reserve la memoire virtuelle sans refus.
# inotify : evite too many open files (Cilium, Falco, Grafana).
- name: Appliquer les sysctl
  ansible.builtin.copy:
    dest: /etc/sysctl.d/99-k8s.conf
    mode: "0644"
    content: |
      net.bridge.bridge-nf-call-iptables  = 1
      net.bridge.bridge-nf-call-ip6tables = 1
      net.ipv4.ip_forward                 = 1
      vm.overcommit_memory                = 1
      vm.panic_on_oom                     = 0
      kernel.panic                        = 10
      fs.inotify.max_user_instances       = 8192
      fs.inotify.max_user_watches         = 524288
  notify: reload sysctl

# Aucun DNS interne : K3s et Ansible resolvent les 3 noms par /etc/hosts.
- name: Resolution inter-VM
  ansible.builtin.blockinfile:
    path: /etc/hosts
    marker: "# {mark} LAB K8S"
    block: |
      192.168.56.10 k8s-master   k8s-master.lab.local
      192.168.56.11 k8s-worker-1 k8s-worker-1.lab.local
      192.168.56.12 k8s-worker-2 k8s-worker-2.lab.local

- name: Installer les paquets de base
  ansible.builtin.apt:
    name: "{{ k8s_base_packages }}"
    state: present

- name: Fuseau horaire
  ansible.builtin.timezone:
    name: "{{ lab_timezone }}"

- name: Ecrire le role du noeud
  ansible.builtin.copy:
    dest: /etc/lab-role
    mode: "0644"
    content: "{{ node_role }}\n"
'@

# ══════════════════════════════════════════════════════════════════════════
# ROLE k3s_server
# ══════════════════════════════════════════════════════════════════════════

W 'ansible/roles/k3s_server/templates/config.yaml.j2' @'
# {{ ansible_managed }}
# node-ip OBLIGATOIRE avec 2 cartes reseau. Sans cette ligne, K3s choisit
# l IP NAT (10.0.2.15) et les agents ne peuvent jamais joindre l API.
node-ip: {{ lab_master_ip }}
advertise-address: {{ lab_master_ip }}

# tls-san : noms et IPs supplementaires dans le certificat de l API.
tls-san:
  - {{ lab_master_ip }}
  - 127.0.0.1

write-kubeconfig-mode: "0644"

# Aucun CNI fourni par K3s : Cilium prend le relais.
flannel-backend: none
# Cilium remplace kube-proxy en eBPF.
disable-kube-proxy: true
# Cilium gere les NetworkPolicy.
disable-network-policy: true

# Chiffrement au repos des Secrets : un fichier de base vole reste illisible.
secrets-encryption: true

disable:
  - traefik
  - servicelb

# Eviction propre plutot qu un noeud fige (un seul disque dans ce labo).
kubelet-arg:
  - eviction-hard=memory.available<150Mi,nodefs.available<10%,imagefs.available<15%

# Taint du control plane : K3s ne le pose PAS par defaut, contrairement a
# kubeadm. Sans lui, un Deployment sans toleration peut atterrir sur le master.
# Les DaemonSets tolerent tout et continuent d y tourner, c est voulu.
node-taint:
  - "node-role.kubernetes.io/control-plane:NoSchedule"
'@

W 'ansible/roles/k3s_server/tasks/main.yml' @'
---
- name: Creer /etc/rancher/k3s
  ansible.builtin.file:
    path: /etc/rancher/k3s
    state: directory
    mode: "0755"

- name: Ecrire la configuration du serveur
  ansible.builtin.template:
    src: config.yaml.j2
    dest: /etc/rancher/k3s/config.yaml
    mode: "0600"
  register: k3s_cfg

# creates : le module shell devient idempotent, pas besoin de when.
- name: Installer K3s server
  ansible.builtin.shell: |
    set -o pipefail
    curl -sfL https://get.k3s.io | INSTALL_K3S_CHANNEL={{ k3s_channel }} sh -s - server
  args:
    executable: /bin/bash
    creates: /usr/local/bin/k3s
  register: k3s_install

- name: Redemarrer k3s si la configuration a change
  ansible.builtin.systemd:
    name: k3s
    state: restarted
  when:
    - k3s_cfg.changed
    - not k3s_install.changed

- name: Activer et demarrer k3s
  ansible.builtin.systemd:
    name: k3s
    enabled: true
    state: started

- name: Attendre l API
  ansible.builtin.command: k3s kubectl get --raw /readyz
  register: api
  until: api.rc == 0
  retries: 60
  delay: 2
  changed_when: false

- name: Creer ~/.kube
  ansible.builtin.file:
    path: /home/vagrant/.kube
    state: directory
    owner: vagrant
    group: vagrant
    mode: "0700"

- name: Copier le kubeconfig
  ansible.builtin.copy:
    src: /etc/rancher/k3s/k3s.yaml
    dest: /home/vagrant/.kube/config
    remote_src: true
    owner: vagrant
    group: vagrant
    mode: "0600"

- name: Exporter KUBECONFIG
  ansible.builtin.copy:
    dest: /etc/profile.d/kube.sh
    mode: "0644"
    content: |
      export KUBECONFIG=/home/vagrant/.kube/config
      alias k=kubectl

- name: Appliquer le taint du control plane
  ansible.builtin.command: >-
    k3s kubectl taint node {{ inventory_hostname }}
    node-role.kubernetes.io/control-plane=:NoSchedule --overwrite
  changed_when: false
  failed_when: false
'@

# ══════════════════════════════════════════════════════════════════════════
# ROLE k3s_agent
# ══════════════════════════════════════════════════════════════════════════

W 'ansible/roles/k3s_agent/templates/config.yaml.j2' @'
# {{ ansible_managed }}
server: https://{{ lab_master_ip }}:6443
token: {{ k3s_token }}

# Sans node-ip, le noeud s enregistre avec l IP NAT et le trafic inter-noeuds
# (kubelet, Cilium, scraping) part sur le mauvais reseau.
node-ip: {{ lab_node_ip }}

# Label pose A L ENREGISTREMENT : cible des nodeSelector.
# role=infra ou role=app selon le noeud.
node-label:
  - role={{ node_role }}

kubelet-arg:
  - eviction-hard=memory.available<150Mi,nodefs.available<10%,imagefs.available<15%
'@

W 'ansible/roles/k3s_agent/tasks/main.yml' @'
---
- name: Creer /etc/rancher/k3s
  ansible.builtin.file:
    path: /etc/rancher/k3s
    state: directory
    mode: "0755"

- name: Ecrire la configuration de l agent
  ansible.builtin.template:
    src: config.yaml.j2
    dest: /etc/rancher/k3s/config.yaml
    mode: "0600"
  register: agent_cfg

# K3S_URL est exige par le script d installation en mode agent.
# no_log : le token n apparait pas dans la sortie, meme avec -vvv.
- name: Installer K3s agent
  ansible.builtin.shell: |
    set -o pipefail
    curl -sfL https://get.k3s.io | \
      INSTALL_K3S_CHANNEL={{ k3s_channel }} \
      K3S_URL=https://{{ lab_master_ip }}:6443 \
      K3S_TOKEN={{ k3s_token }} \
      sh -s - agent
  args:
    executable: /bin/bash
    creates: /usr/local/bin/k3s
  register: agent_install
  no_log: true

- name: Redemarrer k3s-agent si la configuration a change
  ansible.builtin.systemd:
    name: k3s-agent
    state: restarted
  when:
    - agent_cfg.changed
    - not agent_install.changed

- name: Activer et demarrer k3s-agent
  ansible.builtin.systemd:
    name: k3s-agent
    enabled: true
    state: started
'@

# ══════════════════════════════════════════════════════════════════════════
# ROLE bastion
# ══════════════════════════════════════════════════════════════════════════

W 'ansible/roles/bastion/defaults/main.yml' @'
---
bastion_arch: "{{ 'arm64' if ansible_architecture == 'aarch64' else 'amd64' }}"
bastion_trivy_arch: "{{ 'ARM64' if ansible_architecture == 'aarch64' else '64bit' }}"
'@

W 'ansible/roles/bastion/tasks/main.yml' @'
---
- name: Installer jq et gnupg
  ansible.builtin.apt:
    name: [jq, gnupg]
    state: present

- name: Resoudre les dernieres versions GitHub
  ansible.builtin.uri:
    url: "https://api.github.com/repos/{{ item.repo }}/releases/latest"
    return_content: true
  loop:
    - { tool: helm,     repo: "helm/helm" }
    - { tool: trivy,    repo: "aquasecurity/trivy" }
    - { tool: kubeseal, repo: "bitnami-labs/sealed-secrets" }
  register: gh
  retries: 3
  delay: 5
  until: gh is not failed

- name: Construire le dictionnaire des versions
  ansible.builtin.set_fact:
    bver: >-
      {{ dict(gh.results | map(attribute='item.tool')
              | zip(gh.results | map(attribute='json.tag_name'))) }}

# PIEGE : l installeur K3s cree /usr/local/bin/kubectl comme SYMLINK vers k3s.
# curl -o suit le symlink et ecrase k3s : k3s server devient kubectl server.
- name: Supprimer le symlink kubectl
  ansible.builtin.file:
    path: /usr/local/bin/kubectl
    state: absent

- name: Resoudre la version stable de kubectl
  ansible.builtin.uri:
    url: https://dl.k8s.io/release/stable.txt
    return_content: true
  register: kver

- name: Installer kubectl
  ansible.builtin.get_url:
    url: "https://dl.k8s.io/release/{{ kver.content | trim }}/bin/linux/{{ bastion_arch }}/kubectl"
    dest: /usr/local/bin/kubectl
    mode: "0755"

# Sans ce symlink, kubectl lance en root cherche /root/.kube/config qui
# n existe pas (K3s ecrit dans /etc/rancher/k3s/k3s.yaml).
- name: Creer /root/.kube
  ansible.builtin.file:
    path: /root/.kube
    state: directory
    mode: "0700"

- name: Pointer le kubeconfig de root
  ansible.builtin.file:
    src: /etc/rancher/k3s/k3s.yaml
    dest: /root/.kube/config
    state: link
    force: true

- name: Telecharger helm
  ansible.builtin.get_url:
    url: "https://get.helm.sh/helm-{{ bver.helm }}-linux-{{ bastion_arch }}.tar.gz"
    dest: /tmp/helm.tgz
    mode: "0644"

- name: Extraire helm
  ansible.builtin.unarchive:
    src: /tmp/helm.tgz
    dest: /tmp
    remote_src: true
    creates: "/tmp/linux-{{ bastion_arch }}/helm"

- name: Installer helm
  ansible.builtin.copy:
    src: "/tmp/linux-{{ bastion_arch }}/helm"
    dest: /usr/local/bin/helm
    remote_src: true
    mode: "0755"

- name: Telecharger k9s
  ansible.builtin.get_url:
    url: "https://github.com/derailed/k9s/releases/latest/download/k9s_Linux_{{ bastion_arch }}.tar.gz"
    dest: /tmp/k9s.tgz
    mode: "0644"

- name: Extraire k9s
  ansible.builtin.unarchive:
    src: /tmp/k9s.tgz
    dest: /tmp
    remote_src: true
    creates: /tmp/k9s

- name: Installer k9s
  ansible.builtin.copy:
    src: /tmp/k9s
    dest: /usr/local/bin/k9s
    remote_src: true
    mode: "0755"

# Binaire seul plutot qu un depot APT : evite un apt-get update supplementaire.
- name: Telecharger trivy
  ansible.builtin.get_url:
    url: "https://github.com/aquasecurity/trivy/releases/download/{{ bver.trivy }}/trivy_{{ bver.trivy | regex_replace('^v','') }}_Linux-{{ bastion_trivy_arch }}.tar.gz"
    dest: /tmp/trivy.tgz
    mode: "0644"

- name: Extraire trivy
  ansible.builtin.unarchive:
    src: /tmp/trivy.tgz
    dest: /tmp
    remote_src: true
    creates: /tmp/trivy

- name: Installer trivy
  ansible.builtin.copy:
    src: /tmp/trivy
    dest: /usr/local/bin/trivy
    remote_src: true
    mode: "0755"

- name: Telecharger kubeseal
  ansible.builtin.get_url:
    url: "https://github.com/bitnami-labs/sealed-secrets/releases/download/{{ bver.kubeseal }}/kubeseal-{{ bver.kubeseal | regex_replace('^v','') }}-linux-{{ bastion_arch }}.tar.gz"
    dest: /tmp/kubeseal.tgz
    mode: "0644"

- name: Extraire kubeseal
  ansible.builtin.unarchive:
    src: /tmp/kubeseal.tgz
    dest: /tmp
    remote_src: true
    creates: /tmp/kubeseal

- name: Installer kubeseal
  ansible.builtin.copy:
    src: /tmp/kubeseal
    dest: /usr/local/bin/kubeseal
    remote_src: true
    mode: "0755"

- name: Telecharger la CLI cilium
  ansible.builtin.get_url:
    url: "https://github.com/cilium/cilium-cli/releases/latest/download/cilium-linux-{{ bastion_arch }}.tar.gz"
    dest: /tmp/cilium.tgz
    mode: "0644"

- name: Extraire la CLI cilium
  ansible.builtin.unarchive:
    src: /tmp/cilium.tgz
    dest: /tmp
    remote_src: true
    creates: /tmp/cilium

- name: Installer la CLI cilium
  ansible.builtin.copy:
    src: /tmp/cilium
    dest: /usr/local/bin/cilium
    remote_src: true
    mode: "0755"

- name: Nettoyer
  ansible.builtin.file:
    path: "{{ item }}"
    state: absent
  loop:
    - /tmp/helm.tgz
    - /tmp/k9s.tgz
    - /tmp/trivy.tgz
    - /tmp/kubeseal.tgz
    - /tmp/cilium.tgz
    - "/tmp/linux-{{ bastion_arch }}"

- name: Verifier les binaires
  ansible.builtin.stat:
    path: "/usr/local/bin/{{ item }}"
  loop: [kubectl, helm, k9s, trivy, kubeseal, cilium]
  register: bins

- name: Echec si un binaire manque
  ansible.builtin.assert:
    that: item.stat.exists
    fail_msg: "{{ item.item }} absent de /usr/local/bin"
  loop: "{{ bins.results }}"
  loop_control:
    label: "{{ item.item }}"
'@

# ══════════════════════════════════════════════════════════════════════════
# ROLE cilium
# ══════════════════════════════════════════════════════════════════════════

W 'ansible/roles/cilium/defaults/main.yml' @'
---
cilium_version: ""
cilium_namespace: "kube-system"
'@

W 'ansible/roles/cilium/templates/values.yaml.j2' @'
# {{ ansible_managed }}
# Remplacement de kube-proxy : Services implementes en eBPF dans le noyau.
kubeProxyReplacement: true

# OBLIGATOIRE sans kube-proxy : l agent ne peut plus resoudre le Service
# "kubernetes". Il doit joindre l API par son IP reelle (celle du tls-san).
k8sServiceHost: {{ lab_master_ip }}
k8sServicePort: 6443

bpf:
  # SNAT du trafic pod vers Internet (sortie via le NAT VirtualBox).
  masquerade: true

# Envoy embarque dans chaque agent : prerequis des policies L7.
l7Proxy: true

ipv4:
  enabled: true
ipv6:
  enabled: false

# VXLAN : encapsule le trafic inter-noeuds, pas besoin du meme L2.
routingMode: tunnel
tunnelProtocol: vxlan

# Le defaut du chart est 10.0.0.0/8, qui CONTIENT le NAT VirtualBox
# (10.0.2.0/24) : pods injoignables de facon intermittente.
ipam:
  mode: cluster-pool
  operator:
    clusterPoolIPv4PodCIDRList:
      - 10.42.0.0/16
    clusterPoolIPv4MaskSize: 24

# Chemins CNI reels du CRI de K3s 1.37. Verifiable avec k3s crictl info.
# Avec les chemins historiques (data/current/bin), cilium-cni est depose
# la ou containerd ne le cherche pas et les noeuds restent NotReady.
cni:
  binPath: /opt/cni/bin
  confPath: /etc/cni/net.d

operator:
  replicas: 1
  resources:
    requests: { cpu: 50m, memory: 64Mi }
    limits:   { memory: 256Mi }

hubble:
  enabled: true
  relay:
    enabled: true
    # Le relay demarre meme si un noeud est encore NotReady.
    tolerations:
      - operator: Exists
  ui:
    enabled: false

resources:
  requests: { cpu: 100m, memory: 128Mi }
  limits:   { memory: 512Mi }
'@

W 'ansible/roles/cilium/tasks/main.yml' @'
---
# --force-update rend la commande idempotente, sans dependre du texte exact
# du message already exists (qui differe entre helm 3 et helm 4).
- name: Ajouter le depot Helm Cilium
  ansible.builtin.command: helm repo add cilium https://helm.cilium.io/ --force-update
  changed_when: false

- name: Rafraichir l index
  ansible.builtin.command: helm repo update cilium
  changed_when: false

- name: Creer le dossier des values
  ansible.builtin.file:
    path: /home/vagrant/lab-bootstrap/cilium
    state: directory
    owner: vagrant
    group: vagrant
    mode: "0755"

- name: Ecrire les values
  ansible.builtin.template:
    src: values.yaml.j2
    dest: /home/vagrant/lab-bootstrap/cilium/values.yaml
    owner: vagrant
    group: vagrant
    mode: "0644"

# Arguments positionnels AVANT les flags : helm 4 consomme le premier
# positionnel apres --install et echoue avec requires 2 arguments.
# Pas de --wait : hubble-relay ne peut pas etre ordonnance avant que les
# noeuds soient Ready, et les noeuds ne sont Ready qu apres cilium-agent.
- name: Deployer Cilium
  ansible.builtin.command: >-
    helm upgrade cilium cilium/cilium
    --install=true
    --namespace {{ cilium_namespace }}
    {% if cilium_version %}--version {{ cilium_version }}{% endif %}
    --values /home/vagrant/lab-bootstrap/cilium/values.yaml
  register: helm_out
  changed_when: "'has been installed' in helm_out.stdout or 'has been upgraded' in helm_out.stdout"

- name: Attendre le DaemonSet cilium
  ansible.builtin.command: kubectl -n {{ cilium_namespace }} rollout status ds/cilium --timeout=300s
  register: ds
  changed_when: false
  failed_when: false

- name: Attendre l ecriture de la conf CNI
  ansible.builtin.wait_for:
    path: /etc/cni/net.d/05-cilium.conflist
    timeout: 300

# containerd lit sa conf CNI au demarrage. Si Cilium ecrit le fichier APRES,
# le runtime reste sur cni plugin not initialized indefiniment.
- name: Attendre que les noeuds soient Ready
  ansible.builtin.shell: |
    set -o pipefail
    kubectl get nodes --no-headers | grep -c ' Ready '
  register: ready
  until: ready.stdout | int >= 1
  retries: 60
  delay: 5
  changed_when: false

- name: Redemarrer k3s si le runtime n a pas charge la conf
  ansible.builtin.systemd:
    name: k3s
    state: restarted
  when: ready.stdout | int < 1

- name: Rapport
  ansible.builtin.command: cilium status
  changed_when: false
  failed_when: false
'@

# ══════════════════════════════════════════════════════════════════════════
# ROLE argocd
# ══════════════════════════════════════════════════════════════════════════

W 'ansible/roles/argocd/defaults/main.yml' @'
---
argocd_namespace: "argocd"
argocd_chart_version: ""
argocd_host_port: 8080
'@

W 'ansible/roles/argocd/templates/values.yaml.j2' @'
# {{ ansible_managed }}
global:
  # Tous les composants sur worker-1 (label role=infra).
  nodeSelector:
    role: infra

configs:
  params:
    # OBLIGATOIRE pour http://localhost:8080 en HTTP simple. Sans cette cle,
    # argocd-server repond 307 vers HTTPS et le navigateur affiche
    # ERR_SSL_PROTOCOL_ERROR.
    server.insecure: true

# Composants desactives : environ 250 Mo de RAM economises.
dex:
  enabled: false
applicationSet:
  enabled: false
notifications:
  enabled: false

server:
  replicas: 1
  resources:
    requests: { cpu: 50m, memory: 128Mi }
    limits:   { memory: 256Mi }

controller:
  resources:
    requests: { cpu: 100m, memory: 256Mi }
    limits:   { memory: 512Mi }

repoServer:
  resources:
    requests: { cpu: 50m, memory: 128Mi }
    limits:   { memory: 256Mi }

redis:
  resources:
    requests: { cpu: 50m, memory: 64Mi }
    limits:   { memory: 128Mi }
'@

W 'ansible/roles/argocd/templates/pf-argocd.service.j2' @'
[Unit]
Description=Port-forward Argo CD UI vers localhost:{{ argocd_host_port }}
After=k3s.service network-online.target
Wants=network-online.target

[Service]
# --address 0.0.0.0 : sans lui, kubectl ecoute sur 127.0.0.1 dans la VM et le
# NAT VirtualBox ne voit pas le port.
# --kubeconfig explicite : systemd ne charge pas /etc/profile.d.
ExecStart=/usr/local/bin/kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml \
  -n {{ argocd_namespace }} port-forward svc/argocd-server {{ argocd_host_port }}:80 --address 0.0.0.0
# Le pod argocd-server est recree a chaque upgrade ou eviction, ce qui tue
# le tunnel. systemd le relance en 5 s.
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
'@

W 'ansible/roles/argocd/tasks/main.yml' @'
---
- name: Ajouter le depot Helm Argo
  ansible.builtin.command: helm repo add argo https://argoproj.github.io/argo-helm --force-update
  changed_when: false

- name: Rafraichir l index
  ansible.builtin.command: helm repo update argo
  changed_when: false

- name: Creer le dossier des values
  ansible.builtin.file:
    path: /home/vagrant/lab-bootstrap/argocd
    state: directory
    owner: vagrant
    group: vagrant
    mode: "0755"

- name: Ecrire les values
  ansible.builtin.template:
    src: values.yaml.j2
    dest: /home/vagrant/lab-bootstrap/argocd/values.yaml
    owner: vagrant
    group: vagrant
    mode: "0644"

# --server-side OBLIGATOIRE : les CRD d Argo CD depassent la limite de
# 256 Ko d annotation du client-side apply.
- name: Deployer Argo CD
  ansible.builtin.command: >-
    helm upgrade argocd argo/argo-cd
    --install=true
    --namespace {{ argocd_namespace }}
    --create-namespace
    {% if argocd_chart_version %}--version {{ argocd_chart_version }}{% endif %}
    --values /home/vagrant/lab-bootstrap/argocd/values.yaml
    --server-side=true
    --timeout 10m
  register: helm_out
  changed_when: "'has been installed' in helm_out.stdout or 'has been upgraded' in helm_out.stdout"

- name: Attendre argocd-server
  ansible.builtin.command: kubectl -n {{ argocd_namespace }} rollout status deploy/argocd-server --timeout=300s
  changed_when: false

- name: Attendre argocd-repo-server
  ansible.builtin.command: kubectl -n {{ argocd_namespace }} rollout status deploy/argocd-repo-server --timeout=300s
  changed_when: false

- name: Attendre argocd-application-controller
  ansible.builtin.shell: |
    set -o pipefail
    if kubectl -n {{ argocd_namespace }} get statefulset argocd-application-controller >/dev/null 2>&1; then
      kubectl -n {{ argocd_namespace }} rollout status statefulset/argocd-application-controller --timeout=300s
    else
      kubectl -n {{ argocd_namespace }} rollout status deploy/argocd-application-controller --timeout=300s
    fi
  changed_when: false

- name: Ecrire l unite de port-forward
  ansible.builtin.template:
    src: pf-argocd.service.j2
    dest: /etc/systemd/system/pf-argocd.service
    mode: "0644"
  register: pf

- name: Recharger systemd
  ansible.builtin.systemd:
    daemon_reload: true
  when: pf.changed

- name: Activer le tunnel
  ansible.builtin.systemd:
    name: pf-argocd
    enabled: true
    state: restarted

- name: Attendre le tunnel
  ansible.builtin.pause:
    seconds: 5

- name: Verifier que le port ecoute
  ansible.builtin.shell: |
    set -o pipefail
    ss -tlnp | grep -q ':{{ argocd_host_port }}' && echo OK || echo KO
  register: check
  changed_when: false

- name: Echec si le tunnel n ecoute pas
  ansible.builtin.assert:
    that: check.stdout is search('OK')
    fail_msg: "Port {{ argocd_host_port }} absent : journalctl -u pf-argocd -n 30"
'@

# ══════════════════════════════════════════════════════════════════════════
# ROLE sealed_secrets
# ══════════════════════════════════════════════════════════════════════════

W 'ansible/roles/sealed_secrets/defaults/main.yml' @'
---
sealed_namespace: "kube-system"
sealed_chart_version: ""
sealed_key_backup: "/home/vagrant/backups/sealed-secrets-key.yaml"
'@

W 'ansible/roles/sealed_secrets/templates/values.yaml.j2' @'
# {{ ansible_managed }}
# Le Deployment doit s appeler sealed-secrets-controller : c est le nom que
# kubeseal interroge par defaut. Sans cet override, kubeseal echoue sur
# services sealed-secrets-controller not found.
fullnameOverride: sealed-secrets-controller

resources:
  requests: { cpu: 10m, memory: 32Mi }
  limits:   { memory: 128Mi }
'@

W 'ansible/roles/sealed_secrets/tasks/main.yml' @'
---
- name: Ajouter le depot Helm Sealed Secrets
  ansible.builtin.command: helm repo add sealed-secrets https://bitnami.github.io/sealed-secrets --force-update
  changed_when: false

- name: Rafraichir l index
  ansible.builtin.command: helm repo update sealed-secrets
  changed_when: false

- name: Creer le dossier des values
  ansible.builtin.file:
    path: /home/vagrant/lab-bootstrap/sealed-secrets
    state: directory
    owner: vagrant
    group: vagrant
    mode: "0755"

- name: Ecrire les values
  ansible.builtin.template:
    src: values.yaml.j2
    dest: /home/vagrant/lab-bootstrap/sealed-secrets/values.yaml
    owner: vagrant
    group: vagrant
    mode: "0644"

- name: Deployer le controleur
  ansible.builtin.command: >-
    helm upgrade sealed-secrets sealed-secrets/sealed-secrets
    --install=true
    --namespace {{ sealed_namespace }}
    {% if sealed_chart_version %}--version {{ sealed_chart_version }}{% endif %}
    --values /home/vagrant/lab-bootstrap/sealed-secrets/values.yaml
    --timeout 5m
  register: helm_out
  changed_when: "'has been installed' in helm_out.stdout or 'has been upgraded' in helm_out.stdout"

- name: Attendre le controleur
  ansible.builtin.command: kubectl -n {{ sealed_namespace }} rollout status deploy/sealed-secrets-controller --timeout=300s
  changed_when: false

# La cle privee est generee au premier demarrage et n est pas reproductible.
# Sans elle, tous les *.sealed.yaml du depot deviennent indechiffrables.
- name: Creer le dossier de sauvegarde
  ansible.builtin.file:
    path: "{{ sealed_key_backup | dirname }}"
    state: directory
    owner: vagrant
    group: vagrant
    mode: "0700"

- name: Sauvegarder la cle de scellement
  ansible.builtin.shell: |
    set -o pipefail
    kubectl -n {{ sealed_namespace }} get secret \
      -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml \
      > {{ sealed_key_backup }}
    chown vagrant:vagrant {{ sealed_key_backup }}
    chmod 0600 {{ sealed_key_backup }}
  changed_when: false

- name: Verifier que le backup n est pas vide
  ansible.builtin.stat:
    path: "{{ sealed_key_backup }}"
  register: key

- name: Echec si le backup est invalide
  ansible.builtin.assert:
    that:
      - key.stat.exists
      - key.stat.size > 1000
    fail_msg: "Backup de cle invalide ({{ key.stat.size | default(0) }} octets)"
'@

# ══════════════════════════════════════════════════════════════════════════
# ROLE kyverno
# ══════════════════════════════════════════════════════════════════════════

W 'ansible/roles/kyverno/defaults/main.yml' @'
---
kyverno_namespace: "kyverno"
kyverno_chart_version: ""
'@

W 'ansible/roles/kyverno/templates/values.yaml.j2' @'
# {{ ansible_managed }}
# 1 replique par controleur : le defaut est 3 pour l admission, ce qui
# couterait 300 Mo de plus pour zero benefice sur un labo.
admissionController:
  replicas: 1
  nodeSelector:
    role: infra
  resources:
    requests: { cpu: 50m, memory: 128Mi }
    limits:   { memory: 384Mi }

backgroundController:
  nodeSelector:
    role: infra
  resources:
    requests: { cpu: 20m, memory: 64Mi }
    limits:   { memory: 192Mi }

cleanupController:
  nodeSelector:
    role: infra
  resources:
    requests: { cpu: 10m, memory: 32Mi }
    limits:   { memory: 128Mi }

reportsController:
  nodeSelector:
    role: infra
  resources:
    requests: { cpu: 20m, memory: 64Mi }
    limits:   { memory: 192Mi }
'@

W 'ansible/roles/kyverno/files/policies.yaml' @'
---
# Kyverno 1.20 supprime l execution des ClusterPolicy legacy (kyverno.io/v1).
# Les ValidatingPolicy utilisent CEL, le meme moteur que les
# ValidatingAdmissionPolicy natifs de Kubernetes.
apiVersion: policies.kyverno.io/v1
kind: ValidatingPolicy
metadata:
  name: disallow-latest-tag
spec:
  validationActions:
    - Deny
  matchConstraints:
    resourceRules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["pods"]
    # Sans ces exclusions, Kyverno bloquerait ses propres pods, ceux d Argo CD,
    # de la stack metriques et de Falco.
    namespaceSelector:
      matchExpressions:
        - key: kubernetes.io/metadata.name
          operator: NotIn
          values: [kube-system, kyverno, argocd, monitoring, falco]
  validations:
    - expression: "object.spec.containers.all(c, !c.image.endsWith(':latest'))"
      message: "Tag d image explicite obligatoire (:latest interdit)."
---
apiVersion: policies.kyverno.io/v1
kind: ValidatingPolicy
metadata:
  name: require-resource-limits
spec:
  # Audit : signale sans bloquer. Le passage en Deny casserait le deploiement
  # des charges existantes qui n ont pas encore de limits.
  validationActions:
    - Audit
  evaluation:
    background:
      enabled: true
  matchConstraints:
    resourceRules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["pods"]
    namespaceSelector:
      matchExpressions:
        - key: kubernetes.io/metadata.name
          operator: NotIn
          values: [kube-system, kyverno, argocd, monitoring, falco]
  validations:
    - expression: >-
        object.spec.containers.all(c,
          has(c.resources) && has(c.resources.limits) &&
          'cpu' in c.resources.limits && 'memory' in c.resources.limits)
      message: "CPU et memoire limits obligatoires."
'@

W 'ansible/roles/kyverno/tasks/main.yml' @'
---
- name: Ajouter le depot Helm Kyverno
  ansible.builtin.command: helm repo add kyverno https://kyverno.github.io/kyverno --force-update
  changed_when: false

- name: Rafraichir l index
  ansible.builtin.command: helm repo update kyverno
  changed_when: false

- name: Creer le dossier des values
  ansible.builtin.file:
    path: /home/vagrant/lab-bootstrap/kyverno
    state: directory
    owner: vagrant
    group: vagrant
    mode: "0755"

- name: Ecrire les values
  ansible.builtin.template:
    src: values.yaml.j2
    dest: /home/vagrant/lab-bootstrap/kyverno/values.yaml
    owner: vagrant
    group: vagrant
    mode: "0644"

# --server-side : les CRD Kyverno depassent la limite d annotation du
# client-side apply.
- name: Deployer Kyverno
  ansible.builtin.command: >-
    helm upgrade kyverno kyverno/kyverno
    --install=true
    --namespace {{ kyverno_namespace }}
    --create-namespace
    {% if kyverno_chart_version %}--version {{ kyverno_chart_version }}{% endif %}
    --values /home/vagrant/lab-bootstrap/kyverno/values.yaml
    --server-side=true
    --timeout 10m
  register: helm_out
  changed_when: "'has been installed' in helm_out.stdout or 'has been upgraded' in helm_out.stdout"

- name: Attendre les controleurs
  ansible.builtin.command: >-
    kubectl -n {{ kyverno_namespace }} rollout status deploy/{{ item }} --timeout=300s
  loop:
    - kyverno-admission-controller
    - kyverno-background-controller
    - kyverno-cleanup-controller
    - kyverno-reports-controller
  changed_when: false

- name: Attendre que la CRD soit servie
  ansible.builtin.command: >-
    kubectl wait --for=condition=Established --timeout=120s
    crd/validatingpolicies.policies.kyverno.io
  changed_when: false

- name: Appliquer les policies
  ansible.builtin.command: kubectl apply -f /home/vagrant/ansible/roles/kyverno/files/policies.yaml
  register: pol
  changed_when: "'created' in pol.stdout or 'configured' in pol.stdout"

- name: Laisser Kyverno compiler
  ansible.builtin.pause:
    seconds: 10

- name: Etat des policies
  ansible.builtin.command: kubectl get validatingpolicy
  register: list
  changed_when: false

- name: Rapport
  ansible.builtin.debug:
    msg: "{{ list.stdout_lines }}"
'@

# ══════════════════════════════════════════════════════════════════════════
# ROLE observability
# ══════════════════════════════════════════════════════════════════════════

W 'ansible/roles/observability/defaults/main.yml' @'
---
monitoring_namespace: "monitoring"
grafana_host_port: 3000
grafana_admin_password: "labadmin"
vm_chart_version: ""
grafana_chart_version: ""
'@

W 'ansible/roles/observability/templates/vm-values.yaml.j2' @'
# {{ ansible_managed }}
server:
  # Pas de PVC : les metriques sont jetables sur un labo.
  persistentVolume:
    enabled: false
  nodeSelector:
    role: infra
  resources:
    requests: { cpu: 50m, memory: 128Mi }
    limits:   { memory: 384Mi }

  # Service discovery Kubernetes plutot que des noms de Service en dur : un
  # chart qui renomme son Service ne casse plus le scrape.
  scrape:
    enabled: true
    config:
      global:
        scrape_interval: 30s
      scrape_configs:
        - job_name: node-exporter
          kubernetes_sd_configs:
            - role: pod
              namespaces:
                names: [{{ monitoring_namespace }}]
          relabel_configs:
            - source_labels: [__meta_kubernetes_pod_label_app_kubernetes_io_name]
              action: keep
              regex: prometheus-node-exporter
            - source_labels: [__meta_kubernetes_pod_ip]
              action: replace
              regex: (.+)
              replacement: ${1}:9100
              target_label: __address__
            - source_labels: [__meta_kubernetes_pod_node_name]
              target_label: node

        - job_name: kube-state-metrics
          kubernetes_sd_configs:
            - role: pod
              namespaces:
                names: [{{ monitoring_namespace }}]
          relabel_configs:
            - source_labels: [__meta_kubernetes_pod_label_app_kubernetes_io_name]
              action: keep
              regex: kube-state-metrics
            - source_labels: [__meta_kubernetes_pod_ip]
              action: replace
              regex: (.+)
              replacement: ${1}:8080
              target_label: __address__

        - job_name: cilium
          kubernetes_sd_configs:
            - role: pod
              namespaces:
                names: [kube-system]
          relabel_configs:
            - source_labels: [__meta_kubernetes_pod_label_k8s_app]
              action: keep
              regex: cilium
            - source_labels: [__meta_kubernetes_pod_ip]
              action: replace
              regex: (.+)
              replacement: ${1}:9962
              target_label: __address__
            - source_labels: [__meta_kubernetes_pod_node_name]
              target_label: node

        - job_name: argocd
          kubernetes_sd_configs:
            - role: pod
              namespaces:
                names: [argocd]
          relabel_configs:
            - source_labels: [__meta_kubernetes_pod_label_app_kubernetes_io_name]
              action: keep
              regex: argocd-server
            - source_labels: [__meta_kubernetes_pod_ip]
              action: replace
              regex: (.+)
              replacement: ${1}:8082
              target_label: __address__
'@

W 'ansible/roles/observability/templates/grafana-values.yaml.j2' @'
# {{ ansible_managed }}
nodeSelector:
  role: infra

persistence:
  enabled: false

adminUser: admin
adminPassword: {{ grafana_admin_password }}

resources:
  requests: { cpu: 50m, memory: 128Mi }
  limits:   { memory: 256Mi }

# VictoriaMetrics est 100 pourcent compatible PromQL : Grafana utilise le
# plugin Prometheus natif, aucune difference visible.
datasources:
  datasources.yaml:
    apiVersion: 1
    datasources:
      - name: VictoriaMetrics
        type: prometheus
        access: proxy
        url: http://vm-victoria-metrics-single-server.{{ monitoring_namespace }}.svc.cluster.local:8428
        isDefault: true
        jsonData:
          timeInterval: 30s

# Le provider scanne ce dossier au demarrage. Le dashboard vit dans Git,
# il survit donc a un destroy.
dashboardProviders:
  dashboardproviders.yaml:
    apiVersion: 1
    providers:
      - name: lab
        orgId: 1
        folder: Lab
        type: file
        disableDeletion: false
        editable: true
        options:
          path: /var/lib/grafana/dashboards/lab

dashboardsConfigMaps:
  lab: grafana-lab-dashboards
'@

W 'ansible/roles/observability/templates/pf-grafana.service.j2' @'
[Unit]
Description=Port-forward Grafana vers localhost:{{ grafana_host_port }}
After=k3s.service network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml \
  -n {{ monitoring_namespace }} port-forward svc/grafana {{ grafana_host_port }}:80 --address 0.0.0.0
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
'@

W 'ansible/roles/observability/files/dashboards/lab-cluster.json' @'
{
  "uid": "lab-cluster",
  "title": "Lab DevSecOps - Vue cluster",
  "tags": ["lab", "devsecops"],
  "graphTooltip": 1,
  "refresh": "30s",
  "schemaVersion": 39,
  "time": { "from": "now-30m", "to": "now" },
  "panels": [
    { "id": 1, "type": "stat", "title": "Noeuds Ready", "gridPos": { "h": 4, "w": 6, "x": 0, "y": 0 },
      "targets": [ { "refId": "A", "expr": "sum(kube_node_status_condition{condition=\"Ready\",status=\"true\"})", "instant": true } ],
      "options": { "reduceOptions": { "calcs": ["lastNotNull"] }, "colorMode": "background", "graphMode": "none" },
      "fieldConfig": { "defaults": { "thresholds": { "mode": "absolute", "steps": [ { "color": "red", "value": null }, { "color": "green", "value": 3 } ] } } } },
    { "id": 2, "type": "stat", "title": "Pods Running", "gridPos": { "h": 4, "w": 6, "x": 6, "y": 0 },
      "targets": [ { "refId": "A", "expr": "sum(kube_pod_status_phase{phase=\"Running\"})", "instant": true } ],
      "options": { "reduceOptions": { "calcs": ["lastNotNull"] }, "colorMode": "value", "graphMode": "none" },
      "fieldConfig": { "defaults": { "thresholds": { "mode": "absolute", "steps": [ { "color": "blue", "value": null } ] } } } },
    { "id": 3, "type": "stat", "title": "Pods en erreur", "gridPos": { "h": 4, "w": 6, "x": 12, "y": 0 },
      "targets": [ { "refId": "A", "expr": "sum(kube_pod_status_phase{phase=~\"Pending|Failed|Unknown\"})", "instant": true } ],
      "options": { "reduceOptions": { "calcs": ["lastNotNull"] }, "colorMode": "background", "graphMode": "none" },
      "fieldConfig": { "defaults": { "thresholds": { "mode": "absolute", "steps": [ { "color": "green", "value": null }, { "color": "red", "value": 1 } ] } } } },
    { "id": 4, "type": "stat", "title": "Cibles UP", "gridPos": { "h": 4, "w": 6, "x": 18, "y": 0 },
      "targets": [ { "refId": "A", "expr": "count(up == 1)", "instant": true } ],
      "options": { "reduceOptions": { "calcs": ["lastNotNull"] }, "colorMode": "background", "graphMode": "none" },
      "fieldConfig": { "defaults": { "thresholds": { "mode": "absolute", "steps": [ { "color": "red", "value": null }, { "color": "green", "value": 4 } ] } } } },
    { "id": 5, "type": "timeseries", "title": "CPU par noeud", "gridPos": { "h": 8, "w": 12, "x": 0, "y": 4 },
      "targets": [ { "refId": "A", "expr": "100 - (avg by (node) (rate(node_cpu_seconds_total{mode=\"idle\"}[$__rate_interval])) * 100)", "legendFormat": "{{node}}" } ],
      "options": { "legend": { "placement": "bottom" } },
      "fieldConfig": { "defaults": { "unit": "percent", "min": 0, "max": 100, "custom": { "lineWidth": 2, "fillOpacity": 10, "showPoints": "never" } } } },
    { "id": 6, "type": "timeseries", "title": "RAM par noeud", "gridPos": { "h": 8, "w": 12, "x": 12, "y": 4 },
      "targets": [ { "refId": "A", "expr": "(1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100", "legendFormat": "{{node}}" } ],
      "options": { "legend": { "placement": "bottom" } },
      "fieldConfig": { "defaults": { "unit": "percent", "min": 0, "max": 100, "custom": { "lineWidth": 2, "fillOpacity": 10, "showPoints": "never" } } } },
    { "id": 7, "type": "timeseries", "title": "Disque racine", "gridPos": { "h": 8, "w": 8, "x": 0, "y": 12 },
      "targets": [ { "refId": "A", "expr": "(1 - (node_filesystem_avail_bytes{mountpoint=\"/\"} / node_filesystem_size_bytes{mountpoint=\"/\"})) * 100", "legendFormat": "{{node}}" } ],
      "options": { "legend": { "placement": "bottom" } },
      "fieldConfig": { "defaults": { "unit": "percent", "min": 0, "max": 100, "custom": { "lineWidth": 2, "fillOpacity": 10, "showPoints": "never" } } } },
    { "id": 8, "type": "timeseries", "title": "Load average", "gridPos": { "h": 8, "w": 8, "x": 8, "y": 12 },
      "targets": [ { "refId": "A", "expr": "node_load1", "legendFormat": "{{node}}" } ],
      "options": { "legend": { "placement": "bottom" } },
      "fieldConfig": { "defaults": { "custom": { "lineWidth": 2, "fillOpacity": 10, "showPoints": "never" }, "thresholds": { "mode": "absolute", "steps": [ { "color": "green", "value": null }, { "color": "yellow", "value": 2 }, { "color": "red", "value": 4 } ] } } } },
    { "id": 9, "type": "bargauge", "title": "Pods par noeud", "gridPos": { "h": 8, "w": 8, "x": 16, "y": 12 },
      "targets": [ { "refId": "A", "expr": "count by (node) (kube_pod_info)", "legendFormat": "{{node}}", "instant": true } ],
      "options": { "displayMode": "gradient", "reduceOptions": { "calcs": ["lastNotNull"] } } },
    { "id": 10, "type": "stat", "title": "Couverture DaemonSets", "gridPos": { "h": 8, "w": 8, "x": 0, "y": 20 },
      "targets": [ { "refId": "A", "expr": "kube_daemonset_status_number_ready{daemonset=~\"cilium|falco|node-exporter.*\"} / scalar(count(kube_node_info))", "legendFormat": "{{daemonset}}", "instant": true } ],
      "options": { "reduceOptions": { "calcs": ["lastNotNull"] }, "colorMode": "background", "graphMode": "none" },
      "fieldConfig": { "defaults": { "unit": "percentunit", "min": 0, "max": 1, "thresholds": { "mode": "absolute", "steps": [ { "color": "red", "value": null }, { "color": "yellow", "value": 0.66 }, { "color": "green", "value": 1 } ] } } } },
    { "id": 11, "type": "timeseries", "title": "Cilium verdicts", "gridPos": { "h": 8, "w": 8, "x": 8, "y": 20 },
      "targets": [ { "refId": "A", "expr": "sum by (verdict) (rate(cilium_policy_verdict_total[$__rate_interval]))", "legendFormat": "{{verdict}}" } ],
      "options": { "legend": { "placement": "bottom" } },
      "fieldConfig": { "defaults": { "unit": "pps", "custom": { "lineWidth": 2, "fillOpacity": 30, "showPoints": "never", "stacking": { "mode": "normal" } } } } },
    { "id": 12, "type": "timeseries", "title": "HPA replicas", "gridPos": { "h": 8, "w": 8, "x": 16, "y": 20 },
      "targets": [
        { "refId": "A", "expr": "kube_horizontalpodautoscaler_status_desired_replicas", "legendFormat": "desired" },
        { "refId": "B", "expr": "kube_horizontalpodautoscaler_status_current_replicas", "legendFormat": "current" } ],
      "options": { "legend": { "placement": "bottom" } },
      "fieldConfig": { "defaults": { "min": 0, "custom": { "lineWidth": 2, "fillOpacity": 10, "showPoints": "always" } } } },
    { "id": 13, "type": "table", "title": "Pods en erreur (detail)", "gridPos": { "h": 8, "w": 12, "x": 0, "y": 28 },
      "targets": [ { "refId": "A", "expr": "kube_pod_status_phase{phase=~\"Pending|Failed|Unknown\"} > 0", "format": "table", "instant": true } ] },
    { "id": 14, "type": "table", "title": "Conteneurs qui ne demarrent pas", "gridPos": { "h": 8, "w": 12, "x": 12, "y": 28 },
      "targets": [ { "refId": "A", "expr": "kube_pod_container_status_waiting_reason{reason=~\"CrashLoopBackOff|ImagePullBackOff|ErrImagePull|CreateContainerConfigError\"} > 0", "format": "table", "instant": true } ] },
    { "id": 15, "type": "table", "title": "Redemarrages 1h", "gridPos": { "h": 8, "w": 12, "x": 0, "y": 36 },
      "targets": [ { "refId": "A", "expr": "sum by (namespace, pod) (increase(kube_pod_container_status_restarts_total[1h])) > 0", "format": "table", "instant": true } ] },
    { "id": 16, "type": "stat", "title": "ArgoCD Synced", "gridPos": { "h": 8, "w": 6, "x": 12, "y": 36 },
      "targets": [ { "refId": "A", "expr": "count(argocd_app_info{sync_status=\"Synced\"})", "instant": true } ],
      "options": { "reduceOptions": { "calcs": ["lastNotNull"] }, "colorMode": "background", "graphMode": "none" },
      "fieldConfig": { "defaults": { "thresholds": { "mode": "absolute", "steps": [ { "color": "red", "value": null }, { "color": "green", "value": 2 } ] } } } },
    { "id": 17, "type": "stat", "title": "ArgoCD non Healthy", "gridPos": { "h": 8, "w": 6, "x": 18, "y": 36 },
      "targets": [ { "refId": "A", "expr": "count(argocd_app_info{health_status!=\"Healthy\"})", "instant": true } ],
      "options": { "reduceOptions": { "calcs": ["lastNotNull"] }, "colorMode": "background", "graphMode": "none" },
      "fieldConfig": { "defaults": { "thresholds": { "mode": "absolute", "steps": [ { "color": "green", "value": null }, { "color": "red", "value": 1 } ] } } } }
  ]
}
'@

W 'ansible/roles/observability/tasks/main.yml' @'
---
- name: Ajouter les depots Helm
  ansible.builtin.command: "helm repo add {{ item.name }} {{ item.url }} --force-update"
  loop:
    - { name: vm,                   url: "https://victoriametrics.github.io/helm-charts/" }
    - { name: prometheus-community, url: "https://prometheus-community.github.io/helm-charts" }
    - { name: grafana,              url: "https://grafana.github.io/helm-charts" }
  changed_when: false

- name: Rafraichir les index
  ansible.builtin.command: "helm repo update {{ item }}"
  loop: [vm, prometheus-community, grafana]
  changed_when: false

- name: Creer le dossier des values
  ansible.builtin.file:
    path: /home/vagrant/lab-bootstrap/observability
    state: directory
    owner: vagrant
    group: vagrant
    mode: "0755"

- name: Ecrire les values VictoriaMetrics
  ansible.builtin.template:
    src: vm-values.yaml.j2
    dest: /home/vagrant/lab-bootstrap/observability/vm-values.yaml
    owner: vagrant
    group: vagrant
    mode: "0644"

- name: Ecrire les values Grafana
  ansible.builtin.template:
    src: grafana-values.yaml.j2
    dest: /home/vagrant/lab-bootstrap/observability/grafana-values.yaml
    owner: vagrant
    group: vagrant
    mode: "0644"

- name: Deployer node-exporter
  ansible.builtin.command: >-
    helm upgrade node-exporter prometheus-community/prometheus-node-exporter
    --install=true
    --namespace {{ monitoring_namespace }}
    --create-namespace
    --set tolerations[0].operator=Exists
    --timeout 5m
  register: ne
  changed_when: "'has been installed' in ne.stdout or 'has been upgraded' in ne.stdout"

- name: Deployer kube-state-metrics
  ansible.builtin.command: >-
    helm upgrade ksm prometheus-community/kube-state-metrics
    --install=true
    --namespace {{ monitoring_namespace }}
    --set nodeSelector.role=infra
    --timeout 5m
  register: ksm
  changed_when: "'has been installed' in ksm.stdout or 'has been upgraded' in ksm.stdout"

- name: Deployer VictoriaMetrics
  ansible.builtin.command: >-
    helm upgrade vm vm/victoria-metrics-single
    --install=true
    --namespace {{ monitoring_namespace }}
    {% if vm_chart_version %}--version {{ vm_chart_version }}{% endif %}
    --values /home/vagrant/lab-bootstrap/observability/vm-values.yaml
    --timeout 10m
  register: vm
  changed_when: "'has been installed' in vm.stdout or 'has been upgraded' in vm.stdout"

# Le ConfigMap doit exister AVANT le helm upgrade de Grafana : sinon le pod
# reste en CreateContainerConfigError (volume monte mais ConfigMap absent).
- name: Creer le ConfigMap des dashboards
  ansible.builtin.shell: |
    set -o pipefail
    kubectl -n {{ monitoring_namespace }} create configmap grafana-lab-dashboards \
      --from-file=lab-cluster.json=/home/vagrant/ansible/roles/observability/files/dashboards/lab-cluster.json \
      --dry-run=client -o yaml | kubectl apply -f -
  register: cm
  changed_when: "'configured' in cm.stdout or 'created' in cm.stdout"

- name: Deployer Grafana
  ansible.builtin.command: >-
    helm upgrade grafana grafana/grafana
    --install=true
    --namespace {{ monitoring_namespace }}
    {% if grafana_chart_version %}--version {{ grafana_chart_version }}{% endif %}
    --values /home/vagrant/lab-bootstrap/observability/grafana-values.yaml
    --timeout 10m
  register: gf
  changed_when: "'has been installed' in gf.stdout or 'has been upgraded' in gf.stdout"

- name: Attendre VictoriaMetrics
  ansible.builtin.shell: |
    set -o pipefail
    for kind in statefulset deployment; do
      kubectl -n {{ monitoring_namespace }} rollout status "$kind/vm-victoria-metrics-single-server" --timeout=60s && exit 0
    done
    exit 1
  register: vmwait
  until: vmwait.rc == 0
  retries: 12
  delay: 10
  changed_when: false

- name: Attendre Grafana
  ansible.builtin.command: kubectl -n {{ monitoring_namespace }} rollout status deploy/grafana --timeout=300s
  changed_when: false

- name: Ecrire l unite de port-forward Grafana
  ansible.builtin.template:
    src: pf-grafana.service.j2
    dest: /etc/systemd/system/pf-grafana.service
    mode: "0644"
  register: pf

- name: Recharger systemd
  ansible.builtin.systemd:
    daemon_reload: true
  when: pf.changed

- name: Activer le tunnel
  ansible.builtin.systemd:
    name: pf-grafana
    enabled: true
    state: restarted

- name: Attendre le tunnel
  ansible.builtin.pause:
    seconds: 5

- name: Verifier que le port ecoute
  ansible.builtin.shell: |
    set -o pipefail
    ss -tlnp | grep -q ':{{ grafana_host_port }}' && echo OK || echo KO
  register: check
  changed_when: false

- name: Echec si le tunnel n ecoute pas
  ansible.builtin.assert:
    that: check.stdout is search('OK')
    fail_msg: "Port {{ grafana_host_port }} absent : journalctl -u pf-grafana -n 30"

# On resout le nom du POD par prefixe : fonctionne que le workload soit un
# StatefulSet ou un Deployment, et survit aux mises a jour du chart.
- name: Attendre que VictoriaMetrics ingere des series
  ansible.builtin.shell: |
    set -o pipefail
    POD=$(kubectl -n {{ monitoring_namespace }} get pods --no-headers \
      | awk '/^vm-victoria-metrics-single/ {print $1; exit}')
    if [ -z "$POD" ]; then echo "pod introuvable"; exit 1; fi
    N=$(kubectl -n {{ monitoring_namespace }} exec "$POD" -- \
      wget -qO- 'http://127.0.0.1:8428/api/v1/query?query=up' | grep -o '"value"' | wc -l)
    echo "series=$N"
    [ "$N" -ge 2 ]
  register: series
  until: series.rc == 0
  retries: 20
  delay: 10
  changed_when: false

- name: Rapport
  ansible.builtin.debug:
    msg:
      - "Grafana    http://localhost:{{ grafana_host_port }}  (admin / {{ grafana_admin_password }})"
      - "VictoriaMetrics  {{ series.stdout | trim }}"
'@

# ══════════════════════════════════════════════════════════════════════════
# ROLE falco
# ══════════════════════════════════════════════════════════════════════════

W 'ansible/roles/falco/defaults/main.yml' @'
---
falco_namespace: "falco"
falco_chart_version: ""
'@

W 'ansible/roles/falco/templates/values.yaml.j2' @'
# {{ ansible_managed }}
# modern_ebpf : sonde eBPF compilee dans le noyau (kernel >= 5.8 requis).
# Debian 13 = kernel 6.12, donc aucun module a compiler, aucun header requis.
driver:
  kind: modern_ebpf

# Pas de falcosidekick : il faudrait un backend de logs centralise.
falcosidekick:
  enabled: false

resources:
  requests: { cpu: 100m, memory: 128Mi }
  limits:   { memory: 512Mi }

# Le chart ne charge que 25 regles "stable". Les regles de detection de
# conteneurs ont ete deplacees vers les depots incubating/sandbox et ne sont
# donc PAS chargees. Sans ces 4 regles, un conteneur compromis passe inapercu.
customRules:
  lab-rules.yaml: |-
    - rule: Lab Package Management in Container
      desc: Execution d un gestionnaire de paquets dans un conteneur.
      condition: >
        spawned_process and container
        and proc.name in (apt, apt-get, aptitude, dpkg, yum, dnf, rpm, apk, pip, pip3, npm)
      output: >
        Package management process in container
        (user=%user.name container=%container.name image=%container.image.repository
         proc=%proc.name cmdline=%proc.cmdline)
      priority: WARNING
      tags: [lab, supply-chain]

    - rule: Lab Write Below Etc
      desc: Ecriture sous /etc depuis un conteneur (tentative de persistance).
      condition: >
        open_write and container
        and fd.name startswith /etc
        and not proc.name in (dpkg, apt, apt-get, apk, rpm, yum, dnf)
      output: >
        File written below /etc
        (user=%user.name container=%container.name file=%fd.name proc=%proc.name)
      priority: WARNING
      tags: [lab, persistence]

    - rule: Lab Crypto Miner Binary
      desc: Execution d un binaire de minage dans un conteneur.
      condition: >
        spawned_process and container
        and proc.name in (xmrig, minerd, cpuminer, ethminer, nbminer)
      output: >
        Crypto miner started
        (user=%user.name container=%container.name proc=%proc.name cmdline=%proc.cmdline)
      priority: CRITICAL
      tags: [lab, cryptomining]

    - rule: Lab Netcat In Container
      desc: Execution de netcat ou socat dans un conteneur (reverse shell).
      condition: >
        spawned_process and container
        and proc.name in (nc, ncat, netcat, socat)
      output: >
        Netcat-like tool in container
        (user=%user.name container=%container.name proc=%proc.name cmdline=%proc.cmdline)
      priority: WARNING
      tags: [lab, reverse-shell]
'@

W 'ansible/roles/falco/tasks/main.yml' @'
---
- name: Ajouter le depot Helm Falco
  ansible.builtin.command: helm repo add falcosecurity https://falcosecurity.github.io/charts --force-update
  changed_when: false

- name: Rafraichir l index
  ansible.builtin.command: helm repo update falcosecurity
  changed_when: false

- name: Creer le dossier des values
  ansible.builtin.file:
    path: /home/vagrant/lab-bootstrap/falco
    state: directory
    owner: vagrant
    group: vagrant
    mode: "0755"

- name: Ecrire les values
  ansible.builtin.template:
    src: values.yaml.j2
    dest: /home/vagrant/lab-bootstrap/falco/values.yaml
    owner: vagrant
    group: vagrant
    mode: "0644"

- name: Deployer Falco
  ansible.builtin.command: >-
    helm upgrade falco falcosecurity/falco
    --install=true
    --namespace {{ falco_namespace }}
    --create-namespace
    {% if falco_chart_version %}--version {{ falco_chart_version }}{% endif %}
    --values /home/vagrant/lab-bootstrap/falco/values.yaml
    --timeout 10m
  register: helm_out
  changed_when: "'has been installed' in helm_out.stdout or 'has been upgraded' in helm_out.stdout"

- name: Attendre le DaemonSet
  ansible.builtin.command: kubectl -n {{ falco_namespace }} rollout status ds/falco --timeout=300s
  changed_when: false

# Sans la sonde chargee, Falco tourne mais ne voit rien : le pod est Ready et
# silencieux, ce qui donne un faux sentiment de securite.
- name: Verifier que la sonde eBPF est chargee
  ansible.builtin.shell: |
    set -o pipefail
    kubectl -n {{ falco_namespace }} logs ds/falco --tail=200 | grep -qiE 'modern_ebpf|bpf probe|Falco initialized'
  register: probe
  until: probe.rc == 0
  retries: 20
  delay: 10
  changed_when: false
  failed_when: false

- name: Echec si la sonde n est pas chargee
  ansible.builtin.assert:
    that: probe.rc == 0
    fail_msg: "Sonde Falco non chargee. Essayer driver.kind: kmod dans values.yaml.j2"

- name: Nombre de pods
  ansible.builtin.command: kubectl -n {{ falco_namespace }} get pods --no-headers
  register: pods
  changed_when: false

- name: Rapport
  ansible.builtin.debug:
    msg: "{{ pods.stdout_lines }}"
'@

# ══════════════════════════════════════════════════════════════════════════
# ROLE motd
# ══════════════════════════════════════════════════════════════════════════

W 'ansible/roles/motd/tasks/main.yml' @'
---
- name: Installer le script MOTD
  ansible.builtin.template:
    src: lab-motd.sh.j2
    dest: /usr/local/sbin/lab-motd
    mode: "0755"

- name: Installer le hook de connexion
  ansible.builtin.copy:
    dest: /etc/profile.d/00-lab-motd.sh
    mode: "0644"
    content: |
      case $- in *i*) ;; *) return 0 2>/dev/null || exit 0 ;; esac
      [ -r /usr/local/sbin/lab-motd ] && /usr/local/sbin/lab-motd

- name: Vider /etc/motd
  ansible.builtin.copy:
    dest: /etc/motd
    content: ""
    mode: "0644"
'@

W 'ansible/roles/motd/templates/lab-motd.sh.j2' @'
#!/usr/bin/env bash
# {{ ansible_managed }}
# Banniere de connexion. ~0.8 s, aucun service, kubectl borne a 3 s.
set -uo pipefail

if [ -t 1 ]; then
  RST=$'\e[0m'; BLD=$'\e[1m'; DIM=$'\e[2m'
  RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; CYA=$'\e[36m'; MAG=$'\e[35m'
else
  RST=; BLD=; DIM=; RED=; GRN=; YEL=; CYA=; MAG=
fi

hdr() { printf '\n%s== %s %s%s\n' "$BLD$CYA" "$1" "----------------------------------------" "$RST"; }
pct() { awk -v u="$1" -v t="$2" 'BEGIN{ if (t+0<=0){print 0; exit} printf "%d", (u*100)/t }'; }
clr() { if [ "$1" -ge 90 ]; then printf '%s' "$RED"; elif [ "$1" -ge 70 ]; then printf '%s' "$YEL"; else printf '%s' "$GRN"; fi; }

kc() {
  sudo -n true 2>/dev/null || return 1
  sudo -n k3s kubectl --request-timeout=3s "$@" 2>/dev/null
}

ROLE=$(cat /etc/lab-role 2>/dev/null || echo "non defini")
[ -r /etc/os-release ] && . /etc/os-release
printf '\n%s  LAB DEVSECOPS K8S  ·  %s%s\n' "$BLD$MAG" "$(hostname -f 2>/dev/null || hostname)" "$RST"
hdr "IDENTITE"
printf '  %-8s %s\n' "Role"   "$ROLE"
printf '  %-8s %s\n' "OS"     "${PRETTY_NAME:-inconnu}"
printf '  %-8s %s\n' "Noyau"  "$(uname -r)"
printf '  %-8s %s\n' "Uptime" "$(uptime -p 2>/dev/null | sed 's/^up //')"

hdr "RESEAU"
while read -r iface cidr; do
  case "$iface" in
    eth0|enp0s3)        label="NAT VirtualBox" ;;
    eth1|enp0s8|enp0s9) label="host-only labo" ;;
    *)                  label="" ;;
  esac
  printf '  %-6s %-18s %s%s%s\n' "$iface" "$cidr" "$DIM" "$label" "$RST"
done < <(ip -4 -o addr show scope global 2>/dev/null | awk '{print $2, $4}')

hdr "RESSOURCES"
read -r _t _u _f _s _c _a < <(free -m | awk '/^Mem:/{print $2,$3,$4,$5,$6,$7}')
real=$((_t - _a)); p=$(pct "$real" "$_t"); c=$(clr "$p")
printf '  %-8s %s%s/%s Mo (%s%%)%s\n' "RAM" "$c" "$real" "$_t" "$p" "$RST"
printf '  %-8s %s vCPU  load %s\n' "CPU" "$(nproc)" "$(cut -d' ' -f1-3 /proc/loadavg)"
read -r size used pc < <(df -h --output=size,used,pcent / 2>/dev/null | tail -1)
printf '  %-8s %s%s / %s (%s)%s\n' "Disque" "$(clr "${pc%\%}")" "$used" "$size" "$pc" "$RST"

hdr "SERVICES"
for u in ssh k3s k3s-agent containerd falco pf-argocd pf-grafana; do
  systemctl cat "${u}.service" >/dev/null 2>&1 || continue
  st=$(systemctl is-active "${u}.service" 2>/dev/null)
  case "$st" in
    active)     dot="${GRN}o${RST}" ;;
    activating) dot="${YEL}.${RST}" ;;
    failed)     dot="${RED}x${RST}" ;;
    *)          dot="${DIM}.${RST}" ;;
  esac
  printf '  %s %-16s %s\n' "$dot" "$u" "$st"
done

NODES=$(kc get nodes --no-headers 2>/dev/null)
if [ -n "${NODES:-}" ]; then
  hdr "CLUSTER"
  printf '  %-14s %-9s %s\n' "NOEUD" "STATUT" "PODS"
  while read -r name status _rest; do
    pods=$(kc get pods -A --field-selector "spec.nodeName=$name" --no-headers 2>/dev/null | wc -l)
    printf '  %-14s %-9s %s\n' "$name" "$status" "$pods"
  done <<< "$NODES"

  APPS=$(kc -n argocd get applications --no-headers 2>/dev/null)
  if [ -n "${APPS:-}" ]; then
    hdr "GITOPS"
    printf '%s\n' "$APPS" | awk '{printf "  %-12s %-9s %s\n", $1, $2, $3}'
  fi
fi

hdr "ACCES"
printf '  %-28s %s\n' "http://localhost:8080"  "Argo CD"
printf '  %-28s %s\n' "http://localhost:3000"  "Grafana (admin / labadmin)"
printf '  %-28s %s\n' "http://localhost:30080" "demo-app"

printf '\n%s  k9s - kubectl get pods -A - lab-motd (relancer)%s\n\n' "$DIM" "$RST"
'@

# ══════════════════════════════════════════════════════════════════════════
# APP
# ══════════════════════════════════════════════════════════════════════════

W 'app/Dockerfile' @'
# nginx unprivileged : ecoute sur 8080 et tourne en uid 101.
# Compatible avec runAsNonRoot + readOnlyRootFilesystem et avec Pod Security
# Admission restricted sur le namespace demo.
FROM nginxinc/nginx-unprivileged:1.29-alpine
COPY index.html /usr/share/nginx/html/index.html
EXPOSE 8080
'@

W 'app/index.html' @'
<!doctype html>
<html lang="fr">
<head>
  <meta charset="utf-8">
  <title>Lab DevSecOps K8s</title>
  <style>
    body { font-family: system-ui, sans-serif; margin: 0; display: grid;
           place-items: center; height: 100vh; background: #0f172a; color: #e2e8f0; }
    .card { text-align: center; padding: 2rem 3rem; border: 1px solid #334155;
            border-radius: 12px; background: #1e293b; }
    h1 { margin: 0 0 .5rem; font-size: 1.6rem; }
    code { background: #0f172a; padding: .2rem .5rem; border-radius: 4px; }
    .ok { color: #22c55e; }
  </style>
</head>
<body>
  <div class="card">
    <h1>Lab DevSecOps K8s <span class="ok">OK</span></h1>
    <p>Pod : <code id="pod">-</code></p>
  </div>
  <script>
    document.getElementById('pod').textContent = location.hostname || 'n/a';
  </script>
</body>
</html>
'@

W 'app/.dockerignore' @'
.git
.github
ansible
gitops
scripts
README.md
'@

# ══════════════════════════════════════════════════════════════════════════
# GITOPS
# ══════════════════════════════════════════════════════════════════════════

W 'gitops/apps/demo/namespace.yaml' @'
apiVersion: v1
kind: Namespace
metadata:
  name: demo
  labels:
    # Niveau le plus strict : impose runAsNonRoot, drop ALL, seccomp.
    # Deuxieme couche de defense, independante de Kyverno.
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
'@

W 'gitops/apps/demo/deployment.yaml' @'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo-app
  namespace: demo
  labels:
    app: demo-app
spec:
  replicas: 2
  revisionHistoryLimit: 2
  selector:
    matchLabels:
      app: demo-app
  strategy:
    type: RollingUpdate
    rollingUpdate:
      # maxUnavailable 1 : un ancien pod part d abord, le service reste
      # disponible. 0 serait plus strict mais incompatible avec un cluster
      # a 2 workers.
      maxUnavailable: 1
      maxSurge: 1
  template:
    metadata:
      labels:
        app: demo-app
    spec:
      # Le spread remplace l anti-affinity dure : il garantit l etalement a
      # 2 replicas ET autorise le HPA a monter a 3, 4 ou 5.
      # nodeTaintsPolicy Honor est indispensable : sans lui, le master tainte
      # est compte comme un domaine vide et le 3e pod reste Pending.
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: DoNotSchedule
          nodeTaintsPolicy: Honor
          labelSelector:
            matchLabels:
              app: demo-app
      securityContext:
        runAsNonRoot: true
        runAsUser: 101
        runAsGroup: 101
        fsGroup: 101
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: app
          # Nom LOGIQUE : kustomize le reecrit en ghcr.io/...:tag.
          # Aucun tag ici, donc aucune derive possible.
          image: demo-app
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 8080
          resources:
            # 50m et non 10m : le HPA cible un pourcentage des requests.
            # Avec 10m le seuil serait a 3 millicores et n importe quelle
            # requete declencherait le scale-up maximum.
            requests:
              cpu: 50m
              memory: 16Mi
            limits:
              cpu: 100m
              memory: 64Mi
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          livenessProbe:
            httpGet:
              path: /
              port: http
            initialDelaySeconds: 5
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /
              port: http
            initialDelaySeconds: 2
            periodSeconds: 5
          volumeMounts:
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: tmp
          emptyDir: {}
'@

W 'gitops/apps/demo/service.yaml' @'
apiVersion: v1
kind: Service
metadata:
  name: demo-app
  namespace: demo
spec:
  # NodePort : accessible sur http://localhost:30080. Le port est ouvert sur
  # TOUS les noeuds, Cilium route vers un pod vivant. Publie sur le master
  # par le Vagrantfile, donc l URL ne change jamais.
  type: NodePort
  selector:
    app: demo-app
  ports:
    - name: http
      port: 80
      targetPort: http
      nodePort: 30080
'@

W 'gitops/apps/demo/hpa.yaml' @'
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: demo-app
  namespace: demo
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: demo-app
  # min 2 : conserve la redondance entre les 2 workers au repos.
  # max 5 : repartition 3/2 avec maxSkew 1. Memoire : 5 x 64Mi de limits.
  minReplicas: 2
  maxReplicas: 5
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          # 30 pourcent des requests. Avec requests.cpu 50m, le seuil est a
          # 15m par pod : atteignable par une charge HTTP reelle.
          averageUtilization: 30
  # Sans behavior, le HPA monte et descend toutes les 15 s et provoque des
  # rollouts inutiles.
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 0
      policies:
        - type: Pods
          value: 2
          periodSeconds: 30
    scaleDown:
      stabilizationWindowSeconds: 60
      policies:
        - type: Pods
          value: 1
          periodSeconds: 30
'@

W 'gitops/apps/demo/kustomization.yaml' @'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: demo
resources:
  - namespace.yaml
  - deployment.yaml
  - service.yaml
  - hpa.yaml
# Point de verrouillage : la CI ne modifie QUE newName et newTag.
# Le Deployment ne contient aucun tag, donc aucune derive possible.
images:
  - name: demo-app
    newName: nginxinc/nginx-unprivileged
    newTag: "1.29-alpine"
'@

W 'gitops/argocd/apps/demo-app.yaml' @'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: demo-app
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/Cocodil313/k8s-devsecops-lab.git
    targetRevision: main
    path: gitops/apps/demo
  destination:
    server: https://kubernetes.default.svc
    namespace: demo
  # ignoreDifferences : Argo CD ignore spec.replicas sur le Deployment.
  # Sans ca, selfHeal revert toute montee du HPA vers la valeur de Git.
  # RespectIgnoreDifferences est OBLIGATOIRE : sans cette syncOption,
  # ignoreDifferences ne masque l ecart que dans l affichage, pas au sync.
  ignoreDifferences:
    - group: apps
      kind: Deployment
      jsonPointers:
        - /spec/replicas
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
      - RespectIgnoreDifferences=true
    retry:
      limit: 5
      backoff:
        duration: 10s
        factor: 2
        maxDuration: 3m
'@

W 'gitops/bootstrap/root-app.yaml' @'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/Cocodil313/k8s-devsecops-lab.git
    targetRevision: main
    path: gitops/argocd/apps
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
'@

# ══════════════════════════════════════════════════════════════════════════
# CI
# ══════════════════════════════════════════════════════════════════════════

W '.github/workflows/ci.yaml' @'
# Gitleaks -> Trivy FS -> build -> Trivy image (rapport) -> push GHCR -> bump
#
# 2 portes BLOQUANTES + 1 porte de RAPPORT.
# Gitleaks et Trivy FS bloquent : un secret commite ou une misconfiguration
# IaC sont des fautes corrigeables. Le scan d image rapporte sans bloquer :
# les CVE de nginx et alpine ne dependent pas du code applicatif, et bloquer
# dessus rend le pipeline rouge en permanence.
name: ci

on:
  push:
    branches: [main]
    paths:
      - 'app/**'
      - '.github/workflows/ci.yaml'
  workflow_dispatch:

permissions:
  contents: write
  packages: write

env:
  IMAGE: ghcr.io/cocodil313/k8s-devsecops-lab

jobs:
  gitleaks:
    name: Gitleaks
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          # Toute l histoire : un secret supprime au commit suivant reste
          # dans l historique.
          fetch-depth: 0
      - name: Detecter les secrets
        run: |
          docker run --rm -v "$PWD:/repo" zricethezav/gitleaks:latest \
            detect --source=/repo --verbose --redact --exit-code 1

  trivy-fs:
    name: Trivy FS
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Scan fichiers et IaC
        uses: aquasecurity/trivy-action@master
        with:
          scan-type: fs
          scan-ref: .
          severity: CRITICAL,HIGH
          exit-code: '1'
          ignore-unfixed: true
          format: table

  build:
    name: Build + Trivy image + Push
    needs: [gitleaks, trivy-fs]
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Calculer le tag
        run: echo "TAG=${GITHUB_SHA::7}" >> $GITHUB_ENV
      - uses: docker/setup-buildx-action@v3
      - name: Login GHCR
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - name: Build
        run: docker build -t "$IMAGE:$TAG" app/
      - name: Scan de l image (rapport)
        uses: aquasecurity/trivy-action@master
        with:
          image-ref: ${{ env.IMAGE }}:${{ env.TAG }}
          severity: CRITICAL,HIGH
          exit-code: '0'
          ignore-unfixed: true
          format: table
      - name: Push
        run: docker push "$IMAGE:$TAG"
      - name: Tag main
        run: |
          docker tag "$IMAGE:$TAG" "$IMAGE:main"
          docker push "$IMAGE:main"

  bump:
    name: Bump tag GitOps
    needs: build
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Mettre a jour kustomization.yaml
        run: |
          TAG=${GITHUB_SHA::7}
          sed -i "s|newName:.*|newName: ${IMAGE}|" gitops/apps/demo/kustomization.yaml
          sed -i "s|newTag:.*|newTag: \"${TAG}\"|" gitops/apps/demo/kustomization.yaml

          git config user.name  "github-actions[bot]"
          git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
          git add gitops/apps/demo/kustomization.yaml

          if git diff --staged --quiet; then
            echo "Aucun changement de tag"
            exit 0
          fi

          git commit -m "chore(gitops): demo-app -> ${TAG}"
          git push
'@

# ══════════════════════════════════════════════════════════════════════════
# SCRIPTS DE TEST
# ══════════════════════════════════════════════════════════════════════════

# Squelette commun a tous les tests.
$COMMON = @'
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
'@

$FOOTER = @'
printf "\n${C_G}PASS : %d${C_0}   ${C_R}FAIL : %d${C_0}   ${C_Y}WARN : %d${C_0}\n\n" "$PASS" "$FAIL" "$WARN"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
'@

W 'scripts/test-prereqs.sh' (@'
# Verifie que le cluster est sain avant tout autre test.
'@ + $COMMON + @'
printf "\n${C_C}########################################${C_0}\n"
printf "${C_C}#  TEST PREREQUIS                       #${C_0}\n"
printf "${C_C}########################################${C_0}\n"

sec "Noeuds"
NB=$(K get nodes --no-headers 2>/dev/null | wc -l)
READY=$(K get nodes --no-headers 2>/dev/null | grep -c ' Ready ')
[ "$NB" -eq 3 ] && ok "3 noeuds enregistres" || ko "$NB noeuds (attendu 3)"
[ "$READY" -eq 3 ] && ok "3 noeuds Ready" || ko "$READY noeuds Ready (attendu 3)"

sec "CNI"
KP=$(K -n kube-system get pods --no-headers 2>/dev/null | grep -c kube-proxy)
[ "$KP" -eq 0 ] && ok "kube-proxy absent (Cilium en remplacement)" || ko "$KP pod kube-proxy present"
CIL=$(K -n kube-system get ds cilium -o jsonpath='{.status.numberReady}/{.status.desiredNumberScheduled}' 2>/dev/null)
[ "$CIL" = "3/3" ] && ok "cilium 3/3" || ko "cilium $CIL"

sec "DaemonSets"
for ds in cilium falco; do
  N=$(K -n kube-system get ds "$ds" -o jsonpath='{.status.numberReady}' 2>/dev/null || \
      K -n falco get ds "$ds" -o jsonpath='{.status.numberReady}' 2>/dev/null)
  [ "${N:-0}" -eq 3 ] && ok "$ds 3/3" || ko "$ds ${N:-0}/3"
done

sec "Sealed Secrets"
K -n kube-system get deploy sealed-secrets-controller >/dev/null 2>&1 \
  && ok "controleur present" || ko "controleur absent"
[ -s /home/vagrant/backups/sealed-secrets-key.yaml ] \
  && ok "cle sauvegardee" || ko "cle absente"

sec "Tunnels"
for s in pf-argocd pf-grafana; do
  systemctl is-active --quiet "$s" && ok "$s active" || ko "$s inactive"
done
'@ + $FOOTER)

W 'scripts/test-argocd.sh' (@'
# Verifie que les Applications Argo CD sont synchronisees.
'@ + $COMMON + @'
printf "\n${C_C}########################################${C_0}\n"
printf "${C_C}#  TEST ARGO CD                         #${C_0}\n"
printf "${C_C}########################################${C_0}\n"

sec "Applications"
APPS=$(K -n argocd get applications --no-headers 2>/dev/null)
[ -n "$APPS" ] && ok "$(echo "$APPS" | wc -l) application(s)" || ko "aucune application"

for app in root demo-app; do
  SYNC=$(K -n argocd get application "$app" -o jsonpath='{.status.sync.status}' 2>/dev/null)
  HEALTH=$(K -n argocd get application "$app" -o jsonpath='{.status.health.status}' 2>/dev/null)
  [ "$SYNC" = "Synced" ] && ok "$app Synced" || ko "$app $SYNC"
  [ "$HEALTH" = "Healthy" ] && ok "$app Healthy" || ko "$app $HEALTH"
done

sec "HPA ignoreDifferences"
ID=$(K -n argocd get application demo-app -o jsonpath='{.spec.ignoreDifferences}' 2>/dev/null)
echo "$ID" | grep -q "/spec/replicas" && ok "ignoreDifferences sur /spec/replicas" || ko "absent"
'@ + $FOOTER)

W 'scripts/test-demo-url.sh' (@'
# Verifie que http://localhost:30080 repond depuis la VM.
'@ + $COMMON + @'
printf "\n${C_C}########################################${C_0}\n"
printf "${C_C}#  TEST URL DEMO                        #${C_0}\n"
printf "${C_C}########################################${C_0}\n"

sec "Service"
TYPE=$(K -n demo get svc demo-app -o jsonpath='{.spec.type}' 2>/dev/null)
[ "$TYPE" = "NodePort" ] && ok "Service NodePort" || ko "Service $TYPE"
NP=$(K -n demo get svc demo-app -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null)
[ "$NP" = "30080" ] && ok "nodePort 30080" || ko "nodePort $NP"

sec "Endpoints"
EP=$(K -n demo get endpoints demo-app -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null | wc -w)
[ "$EP" -ge 1 ] && ok "$EP endpoint(s)" || ko "aucun endpoint"

sec "HTTP"
CODE=$(curl -s -o /dev/null -m 8 -w '%{http_code}' http://127.0.0.1:30080 2>/dev/null || echo 000)
[ "$CODE" = "200" ] && ok "http://127.0.0.1:30080 -> 200" || ko "http://127.0.0.1:30080 -> $CODE"
CODE=$(curl -s -o /dev/null -m 8 -w '%{http_code}' http://192.168.56.10:30080 2>/dev/null || echo 000)
[ "$CODE" = "200" ] && ok "http://192.168.56.10:30080 -> 200" || ko "http://192.168.56.10:30080 -> $CODE"
'@ + $FOOTER)

W 'scripts/test-kyverno.sh' (@'
# Verifie qu une image :latest est refusee a l admission.
'@ + $COMMON + @'
printf "\n${C_C}########################################${C_0}\n"
printf "${C_C}#  TEST KYVERNO                         #${C_0}\n"
printf "${C_C}########################################${C_0}\n"

sec "Policies"
N=$(K get validatingpolicy --no-headers 2>/dev/null | wc -l)
[ "$N" -ge 2 ] && ok "$N ValidatingPolicy" || ko "$N policy (attendu 2)"

sec "Rejet :latest"
cat > /tmp/bad.yaml <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: test-bad-latest
  namespace: demo
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: c
      image: nginx:latest
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
      resources:
        limits:
          cpu: 100m
          memory: 64Mi
YAML
OUT=$(K apply -f /tmp/bad.yaml 2>&1 || true)
echo "$OUT" | grep -q "disallow-latest-tag" && ok "rejete par disallow-latest-tag" || ko "pod accepte"
K -n demo delete pod test-bad-latest --ignore-not-found >/dev/null 2>&1
rm -f /tmp/bad.yaml
'@ + $FOOTER)

W 'scripts/test-falco.sh' (@'
# Verifie que Falco detecte apt-get et un faux binaire de minage.
'@ + $COMMON + @'
printf "\n${C_C}########################################${C_0}\n"
printf "${C_C}#  TEST FALCO                           #${C_0}\n"
printf "${C_C}########################################${C_0}\n"

sec "DaemonSet"
N=$(K -n falco get pods --no-headers 2>/dev/null | grep -c Running)
[ "$N" -eq 3 ] && ok "3 pods Falco Running" || ko "$N pods (attendu 3)"

sec "Detection"
K -n default delete pod falco-test --ignore-not-found >/dev/null 2>&1
K run falco-test --image=debian:13-slim --restart=Never -n default \
  --command -- sh -c "apt-get update >/dev/null 2>&1; ln -sf /bin/sleep /tmp/xmrig; /tmp/xmrig 2" >/dev/null 2>&1
sleep 25
ALERTES=$(K -n falco logs -l app.kubernetes.io/name=falco -c falco --tail=1000 --prefix 2>/dev/null \
          | grep -ciE "package management|Crypto miner")
[ "${ALERTES:-0}" -ge 1 ] && ok "$ALERTES alerte(s) Falco" || ko "aucune alerte"
K -n default delete pod falco-test --ignore-not-found >/dev/null 2>&1
'@ + $FOOTER)

W 'scripts/test-cilium-l7.sh' (@'
# Verifie qu une policy L7 bloque un domaine et laisse passer un autre.
'@ + $COMMON + @'
printf "\n${C_C}########################################${C_0}\n"
printf "${C_C}#  TEST CILIUM L7                       #${C_0}\n"
printf "${C_C}########################################${C_0}\n"

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
if K apply -f /tmp/attacker.yaml >/dev/null 2>&1 && \
   K -n demo wait --for=condition=Ready pod/attacker --timeout=90s >/dev/null 2>&1; then
  ok "pod attacker Ready"
  K apply -f /tmp/cnp.yaml >/dev/null 2>&1
  sleep 20

  sec "Verification"
  if K -n demo exec attacker -- wget -q -T 8 -O /dev/null http://deb.debian.org/ 2>/dev/null; then
    ok "deb.debian.org joignable"
  else
    wn "deb.debian.org injoignable"
  fi
  if K -n demo exec attacker -- wget -q -T 8 -O /dev/null http://crypto-mining.pool/ 2>/dev/null; then
    ko "crypto-mining.pool JOIGNABLE"
  else
    ok "crypto-mining.pool BLOQUE"
  fi
else
  ko "pod attacker non cree"
fi

K -n demo delete pod attacker --ignore-not-found >/dev/null 2>&1
K -n demo delete ciliumnetworkpolicy deny-crypto-mining --ignore-not-found >/dev/null 2>&1
rm -f /tmp/attacker.yaml /tmp/cnp.yaml
'@ + $FOOTER)

W 'scripts/test-sealed-secrets.sh' (@'
# Verifie qu un SealedSecret est dechiffre par le controleur.
'@ + $COMMON + @'
printf "\n${C_C}########################################${C_0}\n"
printf "${C_C}#  TEST SEALED SECRETS                  #${C_0}\n"
printf "${C_C}########################################${C_0}\n"

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

  if kubeseal --controller-name sealed-secrets-controller \
       --controller-namespace kube-system --format yaml \
       < /tmp/secret.yaml > /tmp/sealed.yaml 2>/dev/null; then
    ok "chiffrement reussi"
    grep -q "$VAL" /tmp/sealed.yaml && ko "VALEUR EN CLAIR dans le sealed" || ok "aucune valeur en clair"
    K apply -f /tmp/sealed.yaml >/dev/null 2>&1
    sleep 8
    LU=$(K -n demo get secret demo-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)
    [ "$LU" = "$VAL" ] && ok "dechiffre par le controleur" || ko "valeur incorrecte"
  else
    ko "kubeseal a echoue"
  fi
  rm -f /tmp/secret.yaml /tmp/sealed.yaml
fi
'@ + $FOOTER)

W 'scripts/test-ha.sh' (@'
# Verifie que http://localhost:30080 repond avant, pendant et apres un reschedule.
# Une interruption de quelques secondes pendant la bascule est normale.
'@ + $COMMON + @'
printf "\n${C_C}########################################${C_0}\n"
printf "${C_C}#  TEST HA                              #${C_0}\n"
printf "${C_C}########################################${C_0}\n"

sec "Etat initial"
RUN=$(K -n demo get pods -l app=demo-app --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
[ "$RUN" -ge 2 ] && ok "$RUN pods Running" || ko "$RUN pod (attendu >= 2)"
CODE=$(curl -s -o /dev/null -m 8 -w '%{http_code}' http://127.0.0.1:30080 2>/dev/null)
[ "$CODE" = "200" ] && ok "URL repond avant" || ko "URL $CODE"

sec "Suppression d un pod"
CIBLE=$(K -n demo get pods -l app=demo-app --field-selector=status.phase=Running \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "${CIBLE:-}" ]; then
  K -n demo delete pod "$CIBLE" --wait=false >/dev/null 2>&1
  OKC=0; TOT=0
  for i in $(seq 1 15); do
    C=$(curl -s -o /dev/null -m 4 -w '%{http_code}' http://127.0.0.1:30080 2>/dev/null || echo 000)
    TOT=$((TOT+1))
    [ "$C" = "200" ] && OKC=$((OKC+1))
    sleep 2
  done
  PCT=$((OKC*100/TOT))
  [ "$PCT" -ge 80 ] && ok "URL disponible $OKC/$TOT cycles ($PCT%)" \
                    || ko "URL disponible $OKC/$TOT cycles ($PCT%)"
else
  ko "aucun pod a supprimer"
fi

sec "Reschedule"
sleep 20
RUN2=$(K -n demo get pods -l app=demo-app --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
[ "$RUN2" -ge 2 ] && ok "$RUN2 pods Running apres reschedule" || ko "$RUN2 pod"
CODE=$(curl -s -o /dev/null -m 8 -w '%{http_code}' http://127.0.0.1:30080 2>/dev/null)
[ "$CODE" = "200" ] && ok "URL repond apres" || ko "URL $CODE"
'@ + $FOOTER)

W 'scripts/test-hpa.sh' (@'
# Verifie que le HPA monte sous charge puis redescend.
'@ + $COMMON + @'
printf "\n${C_C}########################################${C_0}\n"
printf "${C_C}#  TEST HPA                             #${C_0}\n"
printf "${C_C}########################################${C_0}\n"

sec "Configuration"
AFF=$(K -n demo get deploy demo-app -o jsonpath='{.spec.template.spec.affinity.podAntiAffinity}' 2>/dev/null)
[ -z "$AFF" ] && ok "aucun podAntiAffinity" || ko "podAntiAffinity present : plafonne a 2 pods"
MIN=$(K -n demo get hpa demo-app -o jsonpath='{.spec.minReplicas}' 2>/dev/null)
MAX=$(K -n demo get hpa demo-app -o jsonpath='{.spec.maxReplicas}' 2>/dev/null)
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
AVANT=$(K -n demo get deploy demo-app -o jsonpath='{.spec.replicas}' 2>/dev/null)
sec "Scale-up (avant=$AVANT)"
if K apply -f /tmp/load.yaml >/dev/null 2>&1 && \
   K -n demo wait --for=condition=Ready pod/load-generator --timeout=60s >/dev/null 2>&1; then
  PIC=${AVANT:-2}
  for i in $(seq 1 40); do
    DEP=$(K -n demo get deploy demo-app -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)
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
    DEP=$(K -n demo get deploy demo-app -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)
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
'@ + $FOOTER)

W 'scripts/test-gitleaks.sh' (@'
# Verifie que Gitleaks detecte un secret non allowliste.
'@ + $COMMON + @'
printf "\n${C_C}########################################${C_0}\n"
printf "${C_C}#  TEST GITLEAKS                        #${C_0}\n"
printf "${C_C}########################################${C_0}\n"

if ! command -v docker >/dev/null 2>&1 && ! command -v gitleaks >/dev/null 2>&1; then
  wn "docker et gitleaks absents : test non execute"
  exit 0
fi

sec "Secret de test"
cat > /tmp/leak.txt <<'LEAK'
-----BEGIN RSA PRIVATE KEY-----
MIIEowIBAAKCAQEAz7X9QW3LMN5PQR2TbGhJkLmNpQrStUvWxYz0123456789abcdef
-----END RSA PRIVATE KEY-----
LEAK
ok "fichier cree"

sec "Detection"
if command -v gitleaks >/dev/null 2>&1; then
  OUT=$(gitleaks detect --source=/tmp --no-git --verbose --exit-code 1 2>&1 || true)
  echo "$OUT" | grep -qiE "private-key|private key" && ok "secret detecte" || ko "non detecte"
else
  OUT=$(docker run --rm -v "/tmp:/scan" zricethezav/gitleaks:latest \
        detect --source=/scan --no-git --verbose --exit-code 1 2>&1 || true)
  echo "$OUT" | grep -qiE "private-key|private key" && ok "secret detecte" || ko "non detecte"
fi
rm -f /tmp/leak.txt
'@ + $FOOTER)

W 'scripts/test-trivy.sh' (@'
# Verifie que Trivy detecte des CVE CRITICAL sur une image EOL.
'@ + $COMMON + @'
printf "\n${C_C}########################################${C_0}\n"
printf "${C_C}#  TEST TRIVY                           #${C_0}\n"
printf "${C_C}########################################${C_0}\n"

if ! command -v trivy >/dev/null 2>&1; then
  wn "trivy absent du PATH"
  exit 0
fi

sec "Scan de node:14-alpine (EOL)"
OUT=$(trivy image --severity CRITICAL --ignore-unfixed --quiet node:14-alpine 2>/dev/null || true)
N=$(echo "$OUT" | awk '/^node:14-alpine/ {next} /CRITICAL/ {n++} END {print n+0}')
[ "${N:-0}" -gt 0 ] && ok "$N CVE CRITICAL fixables (le CI bloquerait)" || wn "aucune CVE CRITICAL"

sec "Scan de notre image"
IMG=$(K -n demo get deploy demo-app -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
if [ -n "${IMG:-}" ]; then
  ok "image deployee : $IMG"
  OUT2=$(trivy image --severity CRITICAL --ignore-unfixed --quiet "$IMG" 2>/dev/null || true)
  N2=$(echo "$OUT2" | awk '/CRITICAL/ {n++} END {print n+0}')
  ok "$N2 CVE CRITICAL sur l image deployee (rapport, non bloquant)"
fi
'@ + $FOOTER)

W 'scripts/run-all-tests.sh' (@'
# Execute tous les tests dans l ordre et agrege le resultat.
# Chaque test est autonome : on peut aussi les lancer un par un.
'@ + @'
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
declare -a RESULTS

for t in "${TESTS[@]}"; do
  if [ ! -f "$DIR/$t" ]; then
    RESULTS+=("SKIP  $t  (fichier absent)")
    continue
  fi
  printf "\n${C_C}-------------------------------------------------------------${C_0}\n"
  printf "${C_C}>>> %s${C_0}\n" "$t"
  if bash "$DIR/$t"; then
    RESULTS+=("${C_G}OK  ${C_0}  $t")
    TOTAL_OK=$((TOTAL_OK+1))
  else
    RESULTS+=("${C_R}KO  ${C_0}  $t")
    TOTAL_KO=$((TOTAL_KO+1))
  fi
done

printf "\n${C_C}=============================================================${C_0}\n"
printf "${C_C}#  RESUME                                                   #${C_0}\n"
printf "${C_C}=============================================================${C_0}\n"
for r in "${RESULTS[@]}"; do
  printf "  %b\n" "$r"
done

printf "\n  ${C_G}OK : %d${C_0}   ${C_R}KO : %d${C_0}\n\n" "$TOTAL_OK" "$TOTAL_KO"
[ "$TOTAL_KO" -eq 0 ] && exit 0 || exit 1
'@)

# ══════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host " $n fichiers crees dans : $R" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

Get-ChildItem -Path $R -Recurse -File |
    Where-Object { $_.FullName -notmatch '\\\.vagrant\\' -and $_.FullName -notmatch '\\keys\\' } |
    ForEach-Object { "  " + $_.FullName.Replace($R + '\', '') } | Sort-Object

Write-Host ""
Write-Host "PROCHAINES ETAPES :" -ForegroundColor Yellow
Write-Host @'
  1. git init && git add -A && git commit -m "init"
  2. git remote add origin https://github.com/<user>/k8s-devsecops-lab.git
  3. git push -u origin main
  4. vagrant up k8s-master && vagrant up k8s-worker-1 && vagrant up k8s-worker-2
  5. vagrant ssh k8s-master -c "sudo apt-get install -y ansible"
  6. vagrant upload ansible /home/vagrant/ansible k8s-master
  7. vagrant upload scripts /home/vagrant/scripts k8s-master
  8. vagrant ssh k8s-master -> cd ~/ansible -> les 12 playbooks
  9. vagrant upload gitops /home/vagrant/gitops k8s-master
 10. kubectl apply -f /home/vagrant/gitops/bootstrap/root-app.yaml
 11. bash ~/scripts/run-all-tests.sh
'@ -ForegroundColor Gray