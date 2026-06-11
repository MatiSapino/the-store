# How To Rápido

Corré los comandos desde la raíz del repo. El `Makefile` detecta la plataforma:

- Linux/WSL2: usa Vagrant (`vagrant` o `vagrant.exe` desde WSL).
- macOS Apple Silicon: usa Lima.

Si todavía no instalaste prerequisitos, usá el setup de tu plataforma:

```bash
bash scripts/setup-linux.sh      # Linux nativo o WSL2
bash scripts/setup-mac.sh        # macOS Apple Silicon
```

En Windows + WSL2, ejecutá los comandos de `make` desde WSL.

## Flujo principal

```bash
make check              # verificar prerequisitos
make up && make deploy  # crear VMs y desplegar The Store
make status             # ver nodos y pods

make replicas           # escalar ui=3 y catalog=2 para la demo
make unreplicas         # volver ui y catalog a 1 replica
make scale              # agregar worker3 al cluster
make descale            # quitar worker3 y volver al cluster base

make dashboard          # desplegar Headlamp en el namespace dashboards
make k9s                # abrir k9s con ansible/k3s.yaml
make dashboard-down     # borrar el namespace dashboards

make down               # destruir las VMs
make recreate           # down + up + deploy
```

## URLs de demo

- Linux/WSL2: The Store queda en `http://192.168.56.10` y Headlamp en `http://192.168.56.10:30091/`.
- macOS Apple Silicon: usá la IP de `cp` que queda escrita en `ansible/inventory/hosts-lima.yml`.

`make dashboard` imprime el token de Headlamp al terminar.
