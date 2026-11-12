# -*- mode: ruby -*-
# vi: set ft=ruby :
# LAB DEVSECOPS K8S - Vagrantfile (VirtualBox) - infrastructure uniquement
# 3 VM Debian 13 CLI / 3 Go / 2 vCPU.
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
# 30080 est publie sur le master : Cilium sert le NodePort sur tous les noeuds
# et le master ne porte aucun pod applicatif. L URL reste stable.
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

# La paire de cles du labo est generee au premier vagrant up si absente.
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
  config.vm.boot_timeout     = 600
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