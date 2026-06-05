SHELL := /usr/bin/env bash

UNAME_S := $(shell uname -s)
UNAME_M := $(shell uname -m)

# Detect platform and pick the right VM backend + ansible wrapper
ifeq ($(UNAME_S),Darwin)
  ifeq ($(UNAME_M),arm64)
    ANSIBLE_SCRIPT := scripts/ansible-lima.sh
    VM_UP_CMD      := bash scripts/lima-up.sh
    VM_DOWN_CMD    := limactl stop cp worker1 worker2 2>/dev/null; limactl delete cp worker1 worker2 2>/dev/null; true
  else
    ANSIBLE_SCRIPT := scripts/ansible-mac.sh
    VM_UP_CMD      := vagrant up
    VM_DOWN_CMD    := vagrant destroy -f
  endif
else
  # Linux or WSL
  ANSIBLE_SCRIPT := scripts/ansible-wsl.sh
  VM_UP_CMD      := vagrant up
  VM_DOWN_CMD    := vagrant destroy -f
endif

KUBECONFIG := ansible/k3s.yaml
PLAYBOOK   := ansible/site.yml

.PHONY: help up down deploy status teardown clean collections check

help:
	@echo "Usage: make <target>"
	@echo ""
	@echo "  up          Bring up all VMs with Vagrant"
	@echo "  down        Destroy all VMs (vagrant destroy -f)"
	@echo "  deploy      Run full Ansible site.yml against running VMs"
	@echo "  status      Show cluster node and pod status"
	@echo "  teardown    Uninstall K3s from VMs (keeps VMs running)"
	@echo "  clean       Stop local Docker registry container"
	@echo "  collections Install required Ansible collections"
	@echo "  check       Verify all host prerequisites are installed"

up:
	$(VM_UP_CMD)

down:
	$(VM_DOWN_CMD)

deploy:
	bash $(ANSIBLE_SCRIPT) $(PLAYBOOK)

# Run a single playbook: make play P=ansible/playbooks/02-install-control-plane.yml
play:
	bash $(ANSIBLE_SCRIPT) $(P)

status:
	KUBECONFIG=$(KUBECONFIG) kubectl get nodes -o wide
	@echo ""
	KUBECONFIG=$(KUBECONFIG) kubectl get pods -A

teardown:
	bash $(ANSIBLE_SCRIPT) ansible/playbooks/99-teardown.yml

clean:
	-docker rm -f registry 2>/dev/null || true

collections:
	cd ansible && ansible-galaxy collection install -r requirements.yml

check:
	@echo "=== Checking prerequisites ==="
	@command -v limactl     >/dev/null && echo "limactl:    OK ($(shell limactl --version))" || echo "limactl:    MISSING — brew install lima"
	@command -v ansible     >/dev/null && echo "ansible:    OK ($(shell ansible --version | head -1))" || echo "ansible:    MISSING"
	@command -v docker      >/dev/null && echo "docker:     OK ($(shell docker --version))" || echo "docker:     MISSING"
	@command -v kubectl     >/dev/null && echo "kubectl:    OK ($(shell kubectl version --client --short 2>/dev/null || kubectl version --client))" || echo "kubectl:    not installed (optional)"
	@echo ""
	@echo "=== Lima VMs ==="
	@limactl list 2>/dev/null || echo "(no Lima VMs yet)"
