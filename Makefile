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

# Registry local (debe coincidir con ansible/inventory/group_vars/all.yml)
REGISTRY_HOST := 127.0.0.1
REGISTRY_PORT := 5050
REGISTRY_URL  := http://$(REGISTRY_HOST):$(REGISTRY_PORT)
APP_NAMESPACE := the-store
SERVICES      := catalog cart orders checkout ui

.PHONY: help up down deploy status teardown clean collections check scale \
        play-01 play-02 play-03 play-04 play-05 play-06

help:
	@echo "Usage: make <target>"
	@echo ""
	@echo "  up          Bring up all VMs with Vagrant"
	@echo "  down        Destroy all VMs (vagrant destroy -f)"
	@echo "  deploy      Run full Ansible site.yml against running VMs"
	@echo "  status      Show cluster node and pod status"
	@echo "  scale       Levantar worker3 y unirlo al cluster (caso 3)"
	@echo "  teardown    Uninstall K3s from VMs (keeps VMs running)"
	@echo "  clean       Stop local Docker registry container"
	@echo "  collections Install required Ansible collections"
	@echo "  check       Verify all host prerequisites are installed"
	@echo ""
	@echo "Playbooks individuales (corren el playbook y verifican su objetivo):"
	@echo "  play-01     01-prepare-nodes.yml          (prepara el SO de los nodos)"
	@echo "  play-02     02-install-control-plane.yml  (verifica: CP Ready)"
	@echo "  play-03     03-join-workers.yml           (verifica: workers Ready)"
	@echo "  play-04     04-bootstrap-registry.yml     (verifica: registry responde)"
	@echo "  play-05     05-build-and-push-images.yml  (verifica: 5 imágenes en el registry)"
	@echo "  play-06     06-deploy-app.yml             (verifica: deployments Available)"
	@echo "  Orden manual recomendado: play-04 -> play-05 -> play-01 -> play-02 -> play-03 -> play-06"

up:
	$(VM_UP_CMD)

down:
	$(VM_DOWN_CMD)

deploy:
	bash $(ANSIBLE_SCRIPT) $(PLAYBOOK)

# Run a single playbook: make play P=ansible/playbooks/02-install-control-plane.yml
play:
	bash $(ANSIBLE_SCRIPT) $(P)

# --- Playbooks individuales: cada target corre su playbook y, si aplica,
#     verifica que cumplió su objetivo. Las verificaciones de cluster (02/03/06)
#     omiten el chequeo si kubectl no está instalado (es opcional, ver `make check`).

play-01:
	bash $(ANSIBLE_SCRIPT) ansible/playbooks/01-prepare-nodes.yml
	@echo "OK: nodos preparados (la ejecución sin errores del playbook es la verificación)."

play-02:
	bash $(ANSIBLE_SCRIPT) ansible/playbooks/02-install-control-plane.yml
	@echo "=== Verificando Control Plane ==="
	@if [ ! -f $(KUBECONFIG) ]; then echo "FALLA: no existe $(KUBECONFIG)"; exit 1; fi; \
	if ! command -v kubectl >/dev/null 2>&1; then echo "kubectl no instalado: omito verificación"; exit 0; fi; \
	KUBECONFIG=$(KUBECONFIG) kubectl get nodes; \
	if KUBECONFIG=$(KUBECONFIG) kubectl get nodes -l node-role.kubernetes.io/control-plane --no-headers | grep -qw Ready; then \
	  echo "OK: Control Plane Ready"; \
	else \
	  echo "FALLA: Control Plane no está Ready"; exit 1; \
	fi

play-03:
	bash $(ANSIBLE_SCRIPT) ansible/playbooks/03-join-workers.yml
	@echo "=== Verificando workers ==="
	@if ! command -v kubectl >/dev/null 2>&1; then echo "kubectl no instalado: omito verificación"; exit 0; fi; \
	KUBECONFIG=$(KUBECONFIG) kubectl get nodes; \
	notready=$$(KUBECONFIG=$(KUBECONFIG) kubectl get nodes --no-headers | grep -cw NotReady || true); \
	workers_ready=$$(KUBECONFIG=$(KUBECONFIG) kubectl get nodes --no-headers -l '!node-role.kubernetes.io/control-plane' | grep -cw Ready || true); \
	if [ "$$notready" -eq 0 ] && [ "$$workers_ready" -ge 1 ]; then \
	  echo "OK: $$workers_ready worker(s) Ready, ningún nodo NotReady"; \
	else \
	  echo "FALLA: notready=$$notready, workers_ready=$$workers_ready"; exit 1; \
	fi

play-04:
	bash $(ANSIBLE_SCRIPT) ansible/playbooks/04-bootstrap-registry.yml
	@echo "=== Verificando registry local ==="
	@if curl -fsS $(REGISTRY_URL)/v2/ >/dev/null 2>&1; then \
	  echo "OK: registry responde en $(REGISTRY_URL)"; \
	else \
	  echo "FALLA: registry no responde en $(REGISTRY_URL)"; exit 1; \
	fi

play-05:
	bash $(ANSIBLE_SCRIPT) ansible/playbooks/05-build-and-push-images.yml
	@echo "=== Verificando imágenes en el registry ==="
	@missing=0; \
	for svc in $(SERVICES); do \
	  if curl -fsS $(REGISTRY_URL)/v2/the-store-$$svc/tags/list 2>/dev/null | grep -q '"latest"'; then \
	    echo "  the-store-$$svc:latest  OK"; \
	  else \
	    echo "  the-store-$$svc:latest  FALTA"; missing=1; \
	  fi; \
	done; \
	if [ "$$missing" -ne 0 ]; then echo "FALLA: faltan imágenes en el registry"; exit 1; fi; \
	echo "OK: las $(words $(SERVICES)) imágenes están en el registry"

play-06:
	bash $(ANSIBLE_SCRIPT) ansible/playbooks/06-deploy-app.yml
	@echo "=== Verificando despliegue de The Store ==="
	@if ! command -v kubectl >/dev/null 2>&1; then echo "kubectl no instalado: omito verificación"; exit 0; fi; \
	KUBECONFIG=$(KUBECONFIG) kubectl get deployments -n $(APP_NAMESPACE); \
	if KUBECONFIG=$(KUBECONFIG) kubectl wait deployments --all -n $(APP_NAMESPACE) --for=condition=Available --timeout=120s; then \
	  echo "OK: todos los deployments de $(APP_NAMESPACE) están Available"; \
	else \
	  echo "FALLA: hay deployments no disponibles en $(APP_NAMESPACE)"; exit 1; \
	fi

status:
	KUBECONFIG=$(KUBECONFIG) kubectl get nodes -o wide
	@echo ""
	KUBECONFIG=$(KUBECONFIG) kubectl get pods -A

scale:
	bash scripts/scale.sh

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
