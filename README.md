# OpenShift 4.15 — Assisted Installer & Mirror Offline

**Entorno:** RHEL 9.7 | **OCP:** 4.15 | **IP Servidor:** 172.18.194.190

## Arquitectura

```
                    ┌─────────────────────────────────────┐
                    │      svr-xdc-ocp-agent-server        │
                    │         172.18.194.190               │
                    │                                      │
                    │  ┌────────────┐  ┌────────────────┐ │
                    │  │  Assisted  │  │  Local OCI     │ │
                    │  │  Installer │  │  Registry      │ │
                    │  │  :8080/:8090  │  :5000         │ │
                    │  └────────────┘  └────────────────┘ │
                    │  ┌────────────┐  ┌────────────────┐ │
                    │  │ PostgreSQL │  │   Portainer    │ │
                    │  │  (interno) │  │   :9443        │ │
                    │  └────────────┘  └────────────────┘ │
                    └─────────────────────────────────────┘
```

## Servicios

| Servicio | Puerto | URL |
|---|---|---|
| Assisted Installer Web | 8080 | http://172.18.194.190:8080 |
| API / Health | 8090 | http://172.18.194.190:8090/health |
| Local Registry | 5000 | http://172.18.194.190:5000/v2/_catalog |
| Portainer UI | 9443 | https://172.18.194.190:9443 |

## Contenido del Repositorio

```
ocp-mirror/
├── README.md                  ← este archivo
├── imageset-config.yaml       ← config del mirror (versión OCP)
├── 01-setup-mirror.sh         ← instala oc-mirror y dependencias
├── 02-run-mirror.sh           ← ejecuta el mirror a registry local
├── 03-verify-mirror.sh        ← verifica que el mirror esté completo
└── 04-show-idms.sh            ← muestra ICSP/IDMS para Assisted Installer
```

---

## Prerequisitos

- RHEL 9.x con acceso a internet (para el mirror)
- Docker registry local corriendo en `172.18.194.190:5000`
- Pull secret de Red Hat en `/root/pull-secret.json`
  → Descargar desde: https://console.redhat.com/openshift/install/pull-secret
- Al menos **25GB** libres en `/opt/registry` (para OCP 4.15.0 single version)

---

## Paso 1 — Preparar el entorno

```bash
mkdir -p /root/OC-Mirror
cp *.sh imageset-config.yaml /root/OC-Mirror/
chmod +x /root/OC-Mirror/*.sh
cd /root/OC-Mirror

bash 01-setup-mirror.sh
```

Instala: `oc-mirror`, `oc` CLI, `skopeo`, `jq`, `wget`, `curl`.

---

## Paso 2 — Configurar la versión de OCP

Editá `imageset-config.yaml` para elegir la versión exacta:

```yaml
mirror:
  platform:
    channels:
      - name: stable-4.15
        type: ocp
        minVersion: 4.15.0   # ← cambiar aquí
        maxVersion: 4.15.0   # ← misma versión = solo esa patch (~18GB)
```

> **Importante:** Usar `minVersion: 4.15.0` + `maxVersion: 4.15.99`
> descarga TODAS las patches del canal (~500GB). Fijá ambas al mismo
> valor para bajar solo una versión.

Para cambiar a otra versión (ej. 4.18):
```bash
sed -i 's/4.15/4.18/g' imageset-config.yaml
```

---

## Paso 3 — Ejecutar el mirror

```bash
bash /root/OC-Mirror/02-run-mirror.sh
```

El script:
1. Valida que el registry local responda
2. Carga las credenciales de Red Hat desde `/root/pull-secret.json`
3. Ejecuta `oc-mirror` con `--ignore-history` (fuerza descarga completa)
4. Guarda los archivos ICSP/IDMS en `oc-mirror-workspace/results-*/`

**Tiempo estimado:** 10-30 min según ancho de banda  
**Espacio usado:** ~19GB para OCP 4.15.0

> Si el mirror muestra `0B/s` al finalizar, significa que usó metadata
> anterior. Solucion: `rm -rf oc-mirror-workspace/` y volver a correr.

---

## Paso 4 — Verificar el mirror

```bash
bash /root/OC-Mirror/03-verify-mirror.sh
```

Verifica:
- Conectividad al registry
- Cantidad de repositorios (debe ser > 1)
- Tags de release OCP presentes
- Inspección con skopeo
- Archivos ICSP/IDMS generados

**Resultado esperado:** `✓ Verificación EXITOSA — Mirror listo`

---

## Paso 5 — Configurar Assisted Installer

```bash
bash /root/OC-Mirror/04-show-idms.sh
```

Muestra el contenido del `imageContentSourcePolicy.yaml` y el pull-secret
para usar en la UI del Assisted Installer.

### En la UI (http://172.18.194.190:8080):

1. **Crear Cluster** → nombre + versión OCP 4.15
2. **Pull Secret** → pegar el contenido de `/root/pull-secret.json`
3. **Mirror Settings** → pegar el YAML del `imageContentSourcePolicy.yaml`
4. **Add Hosts** → descargar Discovery ISO
5. Bootear los nodos con la ISO

---

## Stack de contenedores (referencia)

### Red y firewall
```bash
sudo podman network create assisted-net
sudo sysctl -w net.ipv4.ip_forward=1
sudo firewall-cmd --permanent --add-port={8080,8090,9443,5000}/tcp
sudo firewall-cmd --reload
sudo mkdir -p /opt/registry
```

### PostgreSQL
```bash
sudo podman run -d --name postgres --net assisted-net --restart always \
  -e POSTGRES_USER=admin -e POSTGRES_PASSWORD=admin \
  -e POSTGRES_DB=assisted_service \
  postgres:13-alpine
```

### Registry local
```bash
sudo podman run -d --name local-registry --net assisted-net --restart always \
  -p 5000:5000 -v /opt/registry:/var/lib/registry:Z \
  docker.io/library/registry:2
```

### Assisted Installer Backend (API)
```bash
sudo podman run -d --name assisted-installer-local \
  --net assisted-net --restart always -p 8090:8090 \
  -e SERVICE_BASE_URL="http://172.18.194.190:8090" \
  -e IMAGE_SERVICE_BASE_URL="http://172.18.194.190:8090" \
  -e AUTH_TYPE="none" -e DEPLOY_TARGET="onprem" \
  -e DB_HOST=postgres -e DB_PORT=5432 \
  -e DB_USER=admin -e DB_PASS=admin -e DB_NAME=assisted_service \
  -e OS_IMAGES='[{"openshift_version":"4.15","cpu_architecture":"x86_64","display_name":"4.15","url":"https://mirror.openshift.com/pub/openshift-v4/dependencies/rhcos/4.15/latest/rhcos-live.x86_64.iso","version":"4.15"}]' \
  quay.io/edge-infrastructure/assisted-service:latest
```

### Assisted Installer Frontend (UI)
```bash
sudo podman run -d --name assisted-installer-ui \
  --net assisted-net --restart always -p 8080:8080 \
  -e ASSISTED_SERVICE_URL="http://172.18.194.190:8090" \
  -e ALLOW_INSECURE_CONNECTIONS="true" \
  quay.io/edge-infrastructure/assisted-installer-ui:latest
```

---

## Troubleshooting

| Síntoma | Causa | Solución |
|---|---|---|
| `unknown flag: --registry-config` | Flag no existe en oc-mirror | Usar `~/.docker/config.json` (lo hace el script) |
| `unknown flag: --workspace` | Flag no existe en esta versión | Eliminado del script |
| `0B/s` al finalizar | Usó metadata anterior, no descargó nada | `rm -rf oc-mirror-workspace/` y re-ejecutar con `--ignore-history` |
| `error building cincinnati graph image` | Falta `ubi8/ubi-micro` en el registry | Agregar a `additionalImages` en el imageset-config |
| Registry vacío después del mirror | `oc-mirror` guardó en `file://` en vez de `docker://` | Verificar destino en el comando, usar `--ignore-history` |
| Solo 1 repo (`oc-mirror`) en registry | Mismo problema de metadata | `rm -rf oc-mirror-workspace/` y re-ejecutar |

---

## Notas

- El archivo generado por `oc-mirror` v1 es `imageContentSourcePolicy.yaml` (ICSP).
  Las versiones más nuevas de oc-mirror generan `imageDigestMirrorSet.yaml` (IDMS).
  Ambos son compatibles con OCP 4.15.
- El registry local corre en **HTTP** (sin TLS). Por eso todos los comandos
  usan `--dest-skip-tls` y `--dest-use-http`.
- Las credenciales del registry local son placeholder (`unused:unused`) ya que
  no tiene autenticación configurada.
