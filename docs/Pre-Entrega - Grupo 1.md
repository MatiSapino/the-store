# ![][image1]

# **Trabajo Práctico**

# **Pre-Entrega**

# **Despliegue y Gestión del Cluster de Kubernetes**

Fecha de entrega: 06/05/2026

Problemática y contexto

Gestionar un cluster de Kubernetes de forma manual es un proceso complejo y poco confiable. Para levantar un entorno funcional es necesario configurar individualmente cada nodo: instalar dependencias, ajustar parámetros del sistema operativo, inicializar el plano de control y unir los nodos trabajadores. Cualquier error puede resultar en un cluster inconsistente, difícil de diagnosticar y reproducir. En entornos de equipo o laboratorio, el problema se agrava: cada nuevo entorno implica repetir el proceso desde cero, con configuraciones divergentes entre integrantes y alta dependencia del conocimiento individual.

Este trabajo se enfoca en la pregunta previa a cualquier tutorial de Kubernetes: *¿cómo se crea y gestiona el cluster de forma automatizada, reproducible y documentada?* La respuesta combina **Ansible** como motor de automatización con **K3s** como distribución liviana de Kubernetes, ejecutable sobre VMs locales. El objetivo no es únicamente que el cluster funcione, sino que cualquier integrante pueda destruirlo y recrearlo desde cero en menos de 10 minutos ejecutando un único comando.

# Diseño de la solución

La solución se estructura en tres capas bien diferenciadas: la infraestructura de virtualización local, la automatización con Ansible, y el cluster de Kubernetes propiamente dicho.

## Infraestructura local

El entorno corre sobre tres VMs creadas con VirtualBox, todas con Ubuntu 22.04 LTS. Una actúa como Control Plane (scheduling y API de Kubernetes) y las otras dos como Workers (donde corren los contenedores). Las tres VMs comparten una red host-only que permite la comunicación entre ellas y con la máquina del operador.

## Automatización con Ansible

Ansible orquesta el proceso de despliegue mediante un playbook declarativo con las siguientes fases:

1. **Preparación de nodos**: configura el SO de cada VM (módulos de kernel, parámetros de red, desactivación de swap).

2. **Instalación del Control Plane**: instala K3s en modo servidor y recupera el token de unión para workers.

3. **Unión de Workers**: instala K3s en modo agente en las dos VMs restantes, conectándolas al Control Plane.

4. **Registry de imágenes**: levanta un Docker Registry local en el host para las imágenes de la aplicación.

5. **Despliegue de la aplicación**: construye las imágenes de The Store, las sube al registry y aplica el manifiesto de Kubernetes.

## Distribución de Kubernetes: K3s

K3s es una distribución certificada de Kubernetes desarrollada por Rancher. Empaqueta todos los componentes en un único binario e incluye de fábrica containerd como runtime y Flannel como CNI. Esto es ideal para laboratorios donde se quiere demostrar gestión del cluster sin la complejidad operativa de un despliegue enterprise.

## Aplicación de demo: The Store

Como carga de trabajo de validación se usa The Store (github.com/jupmoreno/the-store), fork de la aplicación de referencia de AWS Containers. Es un e-commerce con 5 microservicios: UI (Java/Spring Boot), Catalog (Go), Cart (Java), Orders (Java) y Checkout (Node.js). Todos usan persistencia en memoria.

# Scope del PoC y casos de uso

El PoC tiene como objetivo demostrar el ciclo de vida completo de un cluster de Kubernetes: desde la creación automatizada hasta la recuperación ante fallos. A continuación se describen los casos de uso que se implementarán y presentarán durante la exposición.

Casos de uso:

1. **Creación del cluster desde cero**: partiendo de tres VMs limpias con Ubuntu, ejecutar el playbook de Ansible y llegar a un cluster K3s completamente funcional.

2. **Despliegue de la aplicación The Store**: Con el cluster K3s creado, desplegar los 5 microservicios de The Store, asegurando que estén corriendo y accesibles por HTTP.

3. **Escalado horizontal de workers**: agregar un tercer nodo worker al cluster en caliente, sin interrumpir la aplicación. Ansible ejecuta únicamente el play de unión sobre la nueva VM y Kubernetes redistribuye la carga. Se valida con *kubectl get nodes* y verificando que nuevos pods puedan programarse en el nuevo nodo.

4. **Teardown y re-despliegue**: destruir el cluster completo (incluyendo las VMs) y reconstruirlo desde cero ejecutando el mismo playbook. Demuestra que la solución es 100% reproducible y no depende de estado persistente externo. Esta es la prueba más contundente del valor de la automatización.

**Alcance del POC**: el trabajo se enfoca en la gestión del cluster (creación, escalado, recuperación). No se implementan soluciones de persistencia de datos, alta disponibilidad del Control Plane, ni integración con proveedores cloud. La aplicación The Store se usa en modo in-memory únicamente como carga de trabajo de validación.

# Diagrama de arquitectura

El siguiente diagrama muestra la arquitectura completa de la solución, incluyendo las redes involucradas, los nodos del cluster, el registry de imágenes y los pods de la aplicación The Store.

Detalle de redes

La solución utiliza tres planos de red bien diferenciados. Cada uno tiene un propósito específico y opera con protocolos distintos.

### Red de gestión – 192.168.56.0/24

Es la red por la que Ansible accede a los nodos y por la que los workers se comunican con el Control Plane. Se implementa como una red host-only de VirtualBox (sólo entre el host y las VMs, sin salida a internet).

| Nodo | IP fija | Rol |
| :---- | :---- | :---- |
| Host (Dev/Ops) | 192.168.56.1 | Operador, corre Ansible y el Registry local |
| Control Plane | 192.168.56.10 | API Server de K3s, scheduler. |
| Worker 1 | 192.168.56.11 | Nodo de cómputo, corre pods. |
| Worker 2 | 192.168.56.12 | Nodo de cómputo, corre pods. |

Puertos relevantes en esta red:

| Puerto | Protocolo | Dirección | Descripción |
| :---- | :---- | :---- | :---- |
| 22 | TCP (SSH) | Host → todos los nodos | Ansible ejecuta todos los plays por SSH. |
| 6443 | HTTPS | Workers → Control Plane | Workers se registran y comunican con la API de K3s. |
| 5000 | HTTP | Workers → Host | Los workers hacen pull de imágenes al Registry Local. |
| 10250 | HTTPS | Control Plane → Workers | Kubelet API – el Control Plane consulta el estado de los workers. |

### 

### Red de pods – 10.42.0.0/16

Red virtual interna gestionada automáticamente por Flannel, el plugin CNI incluido en K3s. Cada pod recibe una IP única dentro de este rango. Los pods de distintos nodos se comunican a través de un overlay VXLAN (UDP:8472) que Flannel crea sobre la red de gestión. Ansible configura el firewall para abrir este puerto entre workers.

### Registry Local – 192.168.56.1:5000

El manifiesto del repo usa imágenes locales no publicadas en ningún registry público. Para que los workers puedan hacer pull, se levanta un Docker Registry v2 en el host.

### Exposición HTTP – nginx-ingress :80

El único punto de entrada desde el host a la aplicación. El Ingress enruta el tráfico HTTP entrante al Service UI en el puerto 80\.

# Alternativas consideradas

Durante la etapa de diseño se evaluaron distintas herramientas para cada componente de la solución. A continuación se describe el proceso de decisión y la justificación de las elecciones realizadas.

## Herramienta de automatización

La alternativa principal a Ansible era scripts Bash (el repo original incluye un local.sh que hace esto con Kind). Los scripts no ofrecen idempotencia (ejecutar dos veces puede romper cosas), no manejan errores elegantemente y son difíciles de extender. Ansible es declarativo: describe el estado deseado y llega a él sin importar el estado inicial. Otras alternativas como Terraform o Pulumi fueron descartadas porque están orientadas a provisioning de infraestructura cloud y no al nivel de configuración de OS que necesitamos.

## Distribución de Kubernetes

   **Opciones descartadas**:

1. **Kind**: es la herramienta que usa el repositorio original en local.sh. Crea nodos como contenedores Docker, lo que lo hace ideal para desarrollo local rápido. Sin embargo, al ser un cluster de un único nodo lógico, no permite demostrar la gestión de infraestructura multi-nodo que es el foco del trabajo. Tampoco permite demostrar Ansible de forma significativa ya que todo corre en el Docker local.

2. **Minikube**: similar a Kind, excelente para desarrollo pero pensado para un único nodo. Levanta una VM propia que abstrae completamente la configuración del OS, lo que hace que Ansible no tenga nada útil que hacer.

3. **kubeadm \+ Kubernetes vanilla**: kubeadm es la herramienta oficial para crear clusters Kubernetes desde cero. La descartamos porque requiere configuración manual de muchos componentes (CNI, etcd, kube-proxy) que K3s incluye de fábrica. Para el alcance de este TP, la complejidad adicional no aporta valor diferencial.

4. **kops**: herramienta de HashiCorp para crear clusters de producción en AWS. Requiere una cuenta de AWS con costos reales de infraestructura. Incompatible con el entorno de laboratorio local.

   

   **Opción Seleccionada:**

**K3s \+ Ansible**: K3s instala un cluster Kubernetes completamente funcional rápidamente, incluyendo container runtime (containerd), CNI (Flannel) y soporte para Ingress. Combinado con Ansible, permite demostrar el ciclo completo de gestión de infraestructura: provisioning, configuración, despliegue y recuperación ante fallos, sobre VMs reales multi-nodo.