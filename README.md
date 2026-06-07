# The Store — Despliegue en Kubernetes con K3s y Ansible

Trabajo Práctico — Despliegue y Gestión del Cluster de Kubernetes

**The Store** es una plataforma de e-commerce construida con arquitectura de microservicios, usada como carga de trabajo de validación para demostrar el ciclo de vida completo de un cluster Kubernetes: creación automatizada, despliegue, escalado y recuperación ante fallos.

## Arquitectura de la aplicación

![Architecture](/docs/images/architecture.png)

| Servicio | Lenguaje | Descripción |
|----------|----------|-------------|
| [UI](./src/ui/) | Java (Spring Boot) | Interfaz web principal |
| [Catalog](./src/catalog/) | Go | API de catálogo de productos |
| [Cart](./src/cart/) | Java (Spring Boot) | Gestión del carrito de compras |
| [Orders](./src/orders/) | Java (Spring Boot) | Procesamiento de órdenes |
| [Checkout](./src/checkout/) | Node.js (NestJS) | Orquestación del checkout |

Todos los servicios usan persistencia en memoria.

## Infraestructura

Tres VMs Ubuntu 22.04 LTS gestionadas con Vagrant + VirtualBox, conectadas en una red host-only `192.168.56.0/24`:

| Hostname | IP | CPU | RAM | Rol |
|----------|----|-----|-----|-----|
| `cp` | 192.168.56.10 | 2 | 2 GB | K3s Control Plane |
| `worker1` | 192.168.56.11 | 2 | 1.5 GB | K3s Worker |
| `worker2` | 192.168.56.12 | 2 | 1.5 GB | K3s Worker |

El host del operador actúa como registry local de imágenes en `192.168.56.1:5050`.

La automatización corre con **Ansible** desde el host. K3s se instala en modo server en el CP y en modo agent en los workers.

## Requisitos previos

- [Vagrant 2.4+](https://developer.hashicorp.com/vagrant/install)
- [VirtualBox 7+](https://www.virtualbox.org/wiki/Downloads)
- [Ansible 2.16+](https://docs.ansible.com/ansible/latest/installation_guide/index.html)
- [Docker](https://docs.docker.com/get-docker/) (para el registry local y build de imágenes)
- [kubectl](https://kubernetes.io/docs/tasks/tools/install-kubectl/)

## Uso

### 1. Crear el cluster y desplegar la aplicación

En Windows se recomienda separar responsabilidades:

- Ejecutar **Vagrant/VirtualBox desde PowerShell**, porque las VMs viven en el host Windows.
- Ejecutar **Ansible desde WSL**, usando inventario explícito. Si el repo está bajo `/mnt/c`, Ansible puede ignorar `ansible/ansible.cfg` por permisos world-writable del filesystem de Windows.

```bash
# PowerShell, desde C:\Users\EMINE\Documents\GitHub\the-store
vagrant up
```

```bash
# WSL, desde /mnt/c/Users/EMINE/Documents/GitHub/the-store
bash scripts/ansible-wsl.sh
```

El script copia la clave insegura de Vagrant al home de WSL si hace falta, limpia las host keys de `192.168.56.10-12` y ejecuta el playbook con `ANSIBLE_HOST_KEY_CHECKING=False` e inventario explícito.

La aplicación queda disponible en `http://192.168.56.10` una vez que todos los pods estén en `Running`.

### 2. Verificar el estado del cluster

```bash
kubectl --kubeconfig=ansible/k3s.yaml get nodes
kubectl --kubeconfig=ansible/k3s.yaml get pods -n the-store
```

### 3. Escalar agregando un worker

```bash
make scale
```

El target corre `scripts/scale.sh`, que destapa el bloque `#scale#` de worker3 en `Vagrantfile` y en el inventario que corresponda a la plataforma, levanta la VM (vagrant o lima) y ejecuta los plays `01-prepare-nodes` y `03-join-workers` con `--limit worker3`. Al final verifica con `kubectl get node worker3` que el nodo aparezca `Ready`.

### 4. Teardown completo

```bash
# Destruir todas las VMs (el cluster desaparece con ellas)
vagrant destroy -f
```

### Reconstruir desde cero

```bash
# PowerShell
vagrant destroy -f
vagrant up

# WSL
bash scripts/ansible-wsl.sh
```

## Casos de uso del TP

| # | Caso | Comando principal | Validación |
|---|------|-------------------|------------|
| 1 | Crear cluster desde VMs limpias | `vagrant up` en PowerShell + `bash scripts/ansible-wsl.sh` en WSL | `kubectl get nodes` → 3 nodos Ready |
| 2 | Desplegar The Store | Incluido en `site.yml` (play 06) | `curl http://192.168.56.10` → UI responde |
| 3 | Escalado horizontal | `make scale` | `kubectl get nodes` → 4 nodos Ready |
| 4 | Teardown y redespliegue | `vagrant destroy -f`, `vagrant up` y `bash scripts/ansible-wsl.sh` | Cluster funcional en < 10 min |

## Tests

### E2E (Cypress)

Valida el flujo completo de la aplicación contra el cluster activo:

```bash
bash src/e2e/scripts/run-docker.sh -n host 'http://192.168.56.10'
```

### Load testing

Corre el generador de carga durante 10 minutos:

```bash
bash src/load-generator/scripts/run-docker.sh -n host -t 'http://192.168.56.10' -d 600
```

## Estructura del repositorio

```
the-store/
├── ansible/
│   ├── ansible.cfg
│   ├── inventory/hosts.yml       # 3 nodos con IPs fijas
│   ├── group_vars/all.yml        # variables globales (versión K3s, registry, etc.)
│   ├── site.yml                  # orquestador principal
│   ├── playbooks/                # 7 plays (registry → build → prepare → cp → workers → deploy → teardown)
│   └── templates/                # config containerd para registry inseguro
├── dist/kubernetes.yaml          # manifiestos K8s de los 5 microservicios
├── src/                          # código fuente de los microservicios (no modificar)
├── docs/                         # diagramas
├── samples/                      # datos de demo
└── Vagrantfile                   # define las 3 VMs
```
