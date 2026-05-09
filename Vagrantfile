Vagrant.configure("2") do |config|
  config.vm.box = "ubuntu/jammy64"
  config.vm.box_check_update = false

  # Clave SSH insegura compartida — OK para laboratorio local
  config.ssh.insert_key = false

  nodes = [
    { name: "cp",      ip: "192.168.56.10", cpus: 2, memory: 2048 },
    { name: "worker1", ip: "192.168.56.11", cpus: 2, memory: 1536 },
    { name: "worker2", ip: "192.168.56.12", cpus: 2, memory: 1536 },
  ]

  nodes.each do |node|
    config.vm.define node[:name] do |vm|
      vm.vm.hostname = node[:name]
      vm.vm.network "private_network", ip: node[:ip]

      vm.vm.provider "virtualbox" do |vb|
        vb.name   = "the-store-#{node[:name]}"
        vb.cpus   = node[:cpus]
        vb.memory = node[:memory]
        vb.gui    = false
      end
    end
  end
end
