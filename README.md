# The Store — Despliegue en Kubernetes con K3s y Ansible

Trabajo Práctico — Despliegue y Gestión del Cluster de Kubernetes

**The Store** es una plataforma de e-commerce construida con arquitectura de microservicios, usada como carga de trabajo de validación para demostrar el ciclo de vida completo de un cluster Kubernetes: creación automatizada, despliegue, escalado y recuperación ante fallos.

## Arquitectura de la aplicación


| Servicio                    | Lenguaje           | Descripción                    |
| --------------------------- | ------------------ | ------------------------------ |
| [UI](./src/ui/)             | Java (Spring Boot) | Interfaz web principal         |
| [Catalog](./src/catalog/)   | Go                 | API de catálogo de productos   |
| [Cart](./src/cart/)         | Java (Spring Boot) | Gestión del carrito de compras |
| [Orders](./src/orders/)     | Java (Spring Boot) | Procesamiento de órdenes       |
| [Checkout](./src/checkout/) | Node.js (NestJS)   | Orquestación del checkout      |


Todos los servicios usan persistencia en memoria.

## Infraestructura

Tres VMs Ubuntu 22.04 LTS gestionadas con Vagrant en Linux/WSL2 o Lima en macOS Apple Silicon. El backend de virtualización depende del SO: libvirt+KVM en Linux nativo (recomendado), VirtualBox en WSL2 y Lima en macOS Apple Silicon.


| Hostname  | IP            | CPU | RAM    | Rol               |
| --------- | ------------- | --- | ------ | ----------------- |
| `cp`      | 192.168.56.10 | 2   | 2 GB   | K3s Control Plane |
| `worker1` | 192.168.56.11 | 2   | 1.5 GB | K3s Worker        |
| `worker2` | 192.168.56.12 | 2   | 1.5 GB | K3s Worker        |


El host del operador actúa como registry local de imágenes en `192.168.56.1:5050`.

La automatización corre con **Ansible** desde el host. K3s se instala en modo server en el CP y en modo agent en los workers.

## Requisitos previos

- [Vagrant 2.4+](https://developer.hashicorp.com/vagrant/install) (Linux nativo y Windows + WSL2)
- [Lima](https://lima-vm.io/) (macOS Apple Silicon)
- Un backend de virtualización según el SO:
  - Linux nativo: libvirt + KVM (recomendado) o VirtualBox 7+
  - Windows + WSL2: [VirtualBox 7+](https://www.virtualbox.org/wiki/Downloads)
  - macOS Apple Silicon: Lima con socket_vmnet (lo configura `scripts/setup-mac.sh`)
- CPU con virtualización por hardware habilitada en BIOS (Intel VT-x o AMD-V)
- [Ansible 2.16+](https://docs.ansible.com/ansible/latest/installation_guide/index.html)
- [Docker](https://docs.docker.com/get-docker/) (para el registry local y build de imágenes)
- [kubectl](https://kubernetes.io/docs/tasks/tools/install-kubectl/)

Los scripts en `scripts/setup-`* instalan todo lo de arriba según el SO. Después de correrlos:

```bash
make check
```

En Linux nativo, `scripts/setup-linux.sh` avisa antes de instalar si detecta dos conflictos comunes: BIND9 (`named`) escuchando en el puerto 53, o una interfaz `vboxnet0` huérfana con la subred `192.168.56.0/24`. Los dos chocan con las redes que crea vagrant-libvirt.

## Setup por plataforma

Cada SO tiene un script de bootstrap y un wrapper de `ansible-playbook` que ya conoce el inventario correcto. El `Makefile` auto-detecta el sistema y elige el wrapper, así que en la mayoría de los casos alcanza con `make up && make deploy`.


| Plataforma          | Bootstrap                                                                  | VMs                                                                | Wrapper Ansible + inventario                     |
| ------------------- | -------------------------------------------------------------------------- | ------------------------------------------------------------------ | ------------------------------------------------ |
| Linux nativo        | `bash scripts/setup-linux.sh`                                              | `vagrant up` (libvirt o VirtualBox)                                | `scripts/ansible-wsl.sh` + `hosts.yml`           |
| Windows + WSL2      | PowerShell: `scripts/setup-windows.ps1` WSL: `bash scripts/setup-linux.sh` | `make up` desde WSL (usa `vagrant.exe` si no hay `vagrant` nativo) | `scripts/ansible-wsl.sh` desde WSL + `hosts.yml` |
| macOS Apple Silicon | `bash scripts/setup-mac.sh`                                                | `bash scripts/lima-up.sh`                                          | `scripts/ansible-lima.sh` + `hosts-lima.yml`     |


## Uso

### 1. Crear el cluster y desplegar la aplicación

```bash
make up && make deploy
```

`make up` invoca el provider que detectó el Makefile (Vagrant en Linux/WSL2 o Lima en macOS Apple Silicon). `make deploy` corre el `site.yml` completo: registry local, build y push de las 5 imágenes, preparación de nodos, instalación del CP, unión de los workers y despliegue de The Store.

La aplicación queda en `http://192.168.56.10` en Linux/WSL2. En macOS con Lima, usá la IP de `cp` que `scripts/lima-up.sh` escribe en `ansible/inventory/hosts-lima.yml`.

**Windows + WSL2**: las VMs viven en el host Windows, pero el flujo se puede manejar completo desde WSL. El `Makefile` detecta que no hay `vagrant` nativo y usa `vagrant.exe` vía WSL interop, así que los comandos principales corren igual que en Linux:

```bash
# WSL, desde la carpeta del repo
make check
make up
make deploy
```

Lo mismo aplica para `make down`, `make scale`, `make descale`, `make replicas`, `make unreplicas`, `make status`, `make dashboard` y `make dashboard-down`. El wrapper de WSL copia la clave insegura de Vagrant al home de WSL si hace falta, limpia las host keys de `192.168.56.10-13` y corre el playbook con `ANSIBLE_HOST_KEY_CHECKING=False` e inventario explícito.

### 2. Verificar el estado del cluster

```bash
kubectl --kubeconfig=ansible/k3s.yaml get nodes
kubectl --kubeconfig=ansible/k3s.yaml get pods -n the-store
```

También hay targets de Makefile para las verificaciones habituales:

```bash
make status
make k9s
```

`make k9s` abre la UI de k9s con `KUBECONFIG=ansible/k3s.yaml`.

### Instalar k9s

En Linux/WSL2, si no tenés `k9s` instalado:

```bash
ARCH=$(dpkg --print-architecture)
curl -sL "https://github.com/derailed/k9s/releases/latest/download/k9s_Linux_${ARCH}.tar.gz" -o /tmp/k9s.tar.gz
tar -xzf /tmp/k9s.tar.gz -C /tmp k9s
sudo install /tmp/k9s /usr/local/bin/k9s
k9s version
```

Después podés abrirlo contra el cluster del TP con:

```bash
make k9s
```

### 3. Escalar réplicas de la aplicación

Para mostrar escalado horizontal de workloads sin cambiar el manifiesto base:

```bash
make replicas
```

El target sube `ui` a 3 réplicas y `catalog` a 2, espera el rollout de ambos deployments y muestra los pods resultantes.

Para volver al estado base:

```bash
make unreplicas
```

### 4. Escalar agregando un worker

```bash
make scale
```

El target corre `scripts/scale.sh`, que destapa el bloque `#scale#` de worker3 en los archivos que correspondan a la plataforma, levanta la VM (Vagrant o Lima) y ejecuta los plays `01-prepare-nodes` y `03-join-workers` con `--limit worker3`. Al final verifica con `kubectl get node worker3` que el nodo aparezca `Ready`.

Para volver al cluster base de 3 nodos:

```bash
make descale
```

El target drena `worker3`, lo borra del cluster, destruye la VM y vuelve a comentar el bloque `#scale#`.

### 5. Teardown completo

```bash
make down
```

### Reconstruir desde cero

```bash
make down && make up && make deploy
```

(Windows + WSL2: se puede correr igual desde WSL; `make up`, `make down`, `make scale` y `make descale` usan `vagrant.exe` automáticamente si Vagrant está instalado en Windows.)

## Demo visual (opcional)

Tambien hay un dashboard opcional que se despliega con un solo comando:

```bash
make dashboard
```

Esto corre `ansible/playbooks/07-deploy-dashboards.yml`, que crea el namespace `dashboards` y deja corriendo Headlamp en el control plane (con la misma `toleration` que el ingress):


| Herramienta                       | URL                           | Para qué sirve                                                                                                                                                       |
| --------------------------------- | ----------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [Headlamp](https://headlamp.dev/) | `http://192.168.56.10:30091/` | UI moderna tipo SaaS. Ideal para mostrar la **estructura del Caso 2**: árbol de workloads, services, ingress. Requiere un token que imprime el playbook al terminar. |


El playbook imprime al final:

- las URLs exactas según `k3s_node_ip` de tu inventario,
- el token de Headlamp.

Para bajarlos: `make dashboard-down` (borra el namespace `dashboards`).

**Ejemplo de demostración**:

1. Headlamp abierto: ver los 5 microservicios desplegados y sus services.
2. Browser en `http://192.168.56.10`: la app real funcionando.
3. `make replicas` → ver cómo `ui` pasa a 3 pods y `catalog` a 2 pods.
4. `KUBECONFIG=ansible/k3s.yaml kubectl delete pod -n the-store -l app.kubernetes.io/name=ui` → ver en Headlamp cómo Kubernetes recrea el pod.
5. `make scale` → ver aparecer `worker3` en la vista de nodos de Headlamp.
6. `make unreplicas` y `make descale` → volver al cluster base.
7. `make down && make up && make deploy` (Caso 5) → cluster completo cae y vuelve.

## Casos de uso del TP


| #   | Caso                              | Comando principal                     | Validación                                                     |
| --- | --------------------------------- | ------------------------------------- | -------------------------------------------------------------- |
| 1   | Crear cluster desde VMs limpias   | `make up && make deploy`              | `kubectl get nodes` → 3 nodos Ready                            |
| 2   | Desplegar The Store               | Incluido en `make deploy` (play 06)   | `curl http://192.168.56.10` → UI responde                      |
| 3   | Escalado horizontal de aplicación | `make replicas`                       | `kubectl get pods -n the-store` → más pods de `ui` y `catalog` |
| 4   | Escalado horizontal de cluster    | `make scale`                          | `kubectl get nodes` → 4 nodos Ready                            |
| 5   | Teardown y redespliegue           | `make down && make up && make deploy` | Cluster funcional en < 10 min                                  |


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
│   ├── inventory/
│   │   ├── hosts.yml             # Vagrant + VirtualBox/libvirt (Linux/WSL)
│   │   └── hosts-lima.yml        # macOS Apple Silicon (Lima)
│   ├── group_vars/all.yml        # variables globales (versión K3s, registry, etc.)
│   ├── site.yml                  # orquestador principal
│   ├── playbooks/                # registry → build → prepare → cp → workers → deploy (+ teardown)
│   └── templates/                # config containerd para registry inseguro
├── lima/                         # configs de Lima por VM (cp / worker1-3)
├── ansible/templates/            # registries.yaml, headlamp.yaml.j2
├── dist/kubernetes.yaml          # manifiestos K8s de los 5 microservicios
├── src/                          # código fuente de los microservicios (no modificar)
├── scripts/                      # setup por SO, wrappers de ansible, lima-up, scale/descale
├── docs/                         # documentación de la pre-entrega
├── samples/                      # datos de demo
├── Makefile                      # auto-detecta plataforma → up / deploy / replicas / scale / down
└── Vagrantfile                   # define las 3 VMs (+ worker3 opcional)
```

