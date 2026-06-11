SHELL := /usr/bin/env bash

UNAME_S := $(shell uname -s)

# Detect platform and pick the right VM backend + ansible wrapper.
# macOS = Apple Silicon con Lima; el resto = Linux/WSL con Vagrant.
ifeq ($(UNAME_S),Darwin)
  ANSIBLE_SCRIPT := scripts/ansible-lima.sh
  VM_UP_CMD      := bash scripts/lima-up.sh
  VM_DOWN_CMD    := limactl delete --force cp worker1 worker2 worker3 2>/dev/null; true
else
  # Linux or WSL
  VAGRANT_CMD    := $(shell if command -v vagrant >/dev/null 2>&1; then printf 'vagrant'; elif command -v vagrant.exe >/dev/null 2>&1; then printf 'vagrant.exe'; else printf 'vagrant'; fi)
  ANSIBLE_SCRIPT := scripts/ansible-wsl.sh
  VM_UP_CMD      := $(VAGRANT_CMD) up
  VM_DOWN_CMD    := $(VAGRANT_CMD) destroy -f
endif

KUBECONFIG := ansible/k3s.yaml
PLAYBOOK   := ansible/site.yml

# Registry local (debe coincidir con ansible/inventory/group_vars/all.yml)
REGISTRY_HOST := 127.0.0.1
REGISTRY_PORT := 5050
REGISTRY_URL  := http://$(REGISTRY_HOST):$(REGISTRY_PORT)
APP_NAMESPACE := the-store
SERVICES      := catalog cart orders checkout ui

.PHONY: help up down deploy recreate status watch teardown clean collections check scale descale replicas unreplicas k9s \
        dashboard dashboard-down \
        play-01 play-02 play-03 play-04 play-05 play-06

help:
	@echo "Usage: make <target>"
	@echo ""
	@echo "  up          Bring up all VMs with the detected provider"
	@echo "  down        Destroy all VMs with the detected provider"
	@echo "  deploy      Run full Ansible site.yml against running VMs"
	@echo "  recreate    Teardown + recreate + redeploy"
	@echo "  status      Show cluster node and pod status"
	@echo "  watch       Refrescar pods de the-store cada 1s"
	@echo "  k9s         Abrir k9s usando ansible/k3s.yaml"
	@echo "  scale       Levantar worker3 y unirlo al cluster (caso 3)"
	@echo "  descale     Drenar worker3, destruir la VM y volver al cluster base"
	@echo "  replicas    Escalar ui=3 y catalog=2 para la demo"
	@echo "  unreplicas  Volver ui y catalog a 1 replica"
	@echo "  dashboard   Deployar Headlamp para la demo visual (opcional)"
	@echo "  dashboard-down  Borrar el namespace de dashboards"
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

recreate:
	$(MAKE) down
	$(MAKE) up
	$(MAKE) deploy

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

watch:
	watch -n 1 env KUBECONFIG=$(KUBECONFIG) kubectl -n $(APP_NAMESPACE) get pods

k9s:
	KUBECONFIG=$(KUBECONFIG) k9s

scale:
	bash scripts/scale.sh

descale:
	bash scripts/descale.sh

replicas:
	KUBECONFIG=$(KUBECONFIG) kubectl -n $(APP_NAMESPACE) scale deployment/ui --replicas=3
	KUBECONFIG=$(KUBECONFIG) kubectl -n $(APP_NAMESPACE) scale deployment/catalog --replicas=2
	KUBECONFIG=$(KUBECONFIG) kubectl -n $(APP_NAMESPACE) rollout status deployment/ui --timeout=120s
	KUBECONFIG=$(KUBECONFIG) kubectl -n $(APP_NAMESPACE) rollout status deployment/catalog --timeout=120s
	KUBECONFIG=$(KUBECONFIG) kubectl -n $(APP_NAMESPACE) get pods -l 'app.kubernetes.io/name in (ui,catalog)' -o wide

unreplicas:
	KUBECONFIG=$(KUBECONFIG) kubectl -n $(APP_NAMESPACE) scale deployment/ui --replicas=1
	KUBECONFIG=$(KUBECONFIG) kubectl -n $(APP_NAMESPACE) scale deployment/catalog --replicas=1
	KUBECONFIG=$(KUBECONFIG) kubectl -n $(APP_NAMESPACE) rollout status deployment/ui --timeout=120s
	KUBECONFIG=$(KUBECONFIG) kubectl -n $(APP_NAMESPACE) rollout status deployment/catalog --timeout=120s
	KUBECONFIG=$(KUBECONFIG) kubectl -n $(APP_NAMESPACE) get pods -l 'app.kubernetes.io/name in (ui,catalog)' -o wide

dashboard:
	bash $(ANSIBLE_SCRIPT) ansible/playbooks/07-deploy-dashboards.yml

dashboard-down:
	KUBECONFIG=$(KUBECONFIG) kubectl delete namespace dashboards --ignore-not-found

teardown:
	bash $(ANSIBLE_SCRIPT) ansible/playbooks/99-teardown.yml

clean:
	-docker rm -f registry 2>/dev/null || true

collections:
	cd ansible && ansible-galaxy collection install -r requirements.yml

check:
	@echo "=== Checking prerequisites ==="
	@if command -v ansible >/dev/null; then echo "ansible:    OK ($$(ansible --version | head -1))"; else echo "ansible:    MISSING"; fi
	@if command -v docker  >/dev/null; then echo "docker:     OK ($$(docker --version))"; else echo "docker:     MISSING"; fi
ifeq ($(UNAME_S),Darwin)
	@if command -v limactl >/dev/null; then echo "limactl:    OK ($$(limactl --version))"; else echo "limactl:    MISSING (necesario en macOS Apple Silicon)"; fi
else
	@if command -v vagrant >/dev/null; then echo "vagrant:    OK ($$(vagrant --version))"; elif command -v vagrant.exe >/dev/null; then echo "vagrant:    OK ($$(vagrant.exe --version | tr -d '\r') via vagrant.exe/Windows)"; else echo "vagrant:    MISSING (Linux: instalar Vagrant; WSL: instalar Vagrant en Windows y habilitar interop)"; fi
endif
	@if command -v kubectl >/dev/null; then echo "kubectl:    OK ($$(kubectl version --client 2>/dev/null | head -1))"; else echo "kubectl:    not installed (opcional, solo para verificar el cluster)"; fi
ifeq ($(UNAME_S),Darwin)
	@echo ""
	@echo "=== Lima VMs ==="
	@command -v limactl >/dev/null && limactl list 2>/dev/null || echo "(no Lima VMs)"
endif
