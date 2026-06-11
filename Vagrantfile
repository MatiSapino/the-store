Vagrant.configure("2") do |config|
  config.vm.box = "generic/ubuntu2204"
  config.vm.box_check_update = false

  # Boxes can take longer than 5 min to expose SSH when booting several VMs
  # at once; raise the timeout so Vagrant doesn't cut out before network is up.
  config.vm.boot_timeout = 600

  # Shared insecure key — fine for a local lab
  config.ssh.insert_key = false

  nodes = [
    { name: "cp",      ip: "192.168.56.10", cpus: 2, memory: 2048 },
    { name: "worker1", ip: "192.168.56.11", cpus: 2, memory: 1536 },
    { name: "worker2", ip: "192.168.56.12", cpus: 2, memory: 1536 },
    #scale# { name: "worker3", ip: "192.168.56.13", cpus: 2, memory: 1536 },
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

      vm.vm.provider "libvirt" do |lv|
        lv.driver = "kvm"
        lv.cpu_mode = "host-passthrough"
        lv.cpus   = node[:cpus]
        lv.memory = node[:memory]
        lv.tpm_path = nil
      end
    end
  end
end
