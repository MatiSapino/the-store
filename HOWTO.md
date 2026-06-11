# How To Rápido

En Windows + WSL2, corré todo desde WSL en la carpeta del repo. El `Makefile` usa `vagrant.exe` automáticamente si no hay `vagrant` nativo.

```bash
make check              # verificar prerequisitos
make up && make deploy  # crear VMs y desplegar The Store
make status             # ver nodos y pods
make k9s                # abrir k9s con ansible/k3s.yaml
make scale              # agregar worker3
make descale            # quitar worker3 y volver al cluster base
make down               # destruir las VMs
```
