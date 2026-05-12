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

---

## Script 05 — Generador de ISO para Agent Based Installer

```bash
bash /root/OC-Mirror/05-generate-cluster-iso.sh
```

Wizard interactivo de 7 pasos que genera la ISO de instalación para un cluster OCP de 1 o 3 nodos usando el registry mirror local. No requiere acceso a internet.

### Topologías soportadas

| Tipo | Nodos | Descripción |
|---|---|---|
| SNO | 1 VM | etcd + control plane + worker en una sola máquina |
| HA  | 3 VMs | 3x control plane + etcd, cada nodo también schedulea workloads |

En ambos casos genera **una sola ISO**. Para HA, la misma ISO se monta en las 3 VMs — la diferencia entre nodos se resuelve por MAC address en el `agent-config.yaml`.

### Pasos del wizard

| Paso | Qué hace |
|---|---|
| 1 — Prerequisitos | Verifica `openshift-install`, pull-secret, registry y ICSP |
| 2 — Topología | Elegís 1 (SNO) o 3 (HA) |
| 3 — Datos del cluster | Nombre, dominio, CIDRs, VIPs, DNS, NTP, SSH key |
| 4 — Nodos | MAC, IP estática e interfaz por cada VM |
| 5 — Mirror | Lee el ICSP de oc-mirror y lo inyecta en los configs |
| 6 — Resumen | Muestra todo y pide confirmación |
| 7 — Genera | Produce install-config.yaml + agent-config.yaml + ISO |

### Fixes aplicados al wizard

| Error | Causa | Solución aplicada |
|---|---|---|
| `nmstatectl: executable not found` | nmstate no instalado | `dnf install -y nmstate` antes de correr el wizard |
| `unknown field macAddress at line 7` | nmstatectl v2 no acepta MAC dentro de `networkConfig.interfaces` | MAC removida del bloque networkConfig, agregado bloque `ethernet:` y `ipv6: enabled: false` |

### Prerequisito adicional — nmstate

```bash
# Instalar antes de correr el wizard
dnf install -y nmstate

# Verificar version
nmstatectl version
```

### Estructura correcta del networkConfig (nmstatectl v2.x)

```yaml
hosts:
  - hostname: master-0
    role: master
    interfaces:
      - name: ens192
        macAddress: AA:BB:CC:DD:EE:FF   # MAC solo aqui
    networkConfig:
      interfaces:
        - name: ens192
          type: ethernet
          state: up
          ethernet:                      # requerido en nmstate v2
            auto-negotiation: true
          ipv4:
            enabled: true
            address:
              - ip: 172.18.194.191
                prefix-length: 24
            dhcp: false
          ipv6:
            enabled: false              # requerido explicitamente
      dns-resolver:
        config:
          server:
            - 172.18.194.36
            - 172.18.194.37
      routes:
        config:
          - destination: 0.0.0.0/0
            next-hop-address: 172.18.194.1
            next-hop-interface: ens192
            table-id: 254
```

### Registros DNS requeridos

El wizard los muestra en pantalla en cuanto ingresás nombre, dominio y VIPs. Deben crearse **antes de bootear las VMs** con la ISO.

#### Para HA (3 nodos)

```
# API
api.CLUSTER.DOMINIO.      IN A   API_VIP
api-int.CLUSTER.DOMINIO.  IN A   API_VIP

# Ingress / Apps
*.apps.CLUSTER.DOMINIO.   IN A   INGRESS_VIP

# DNS inverso
X.X.X.X.in-addr.arpa.    IN PTR  api.CLUSTER.DOMINIO.
X.X.X.X.in-addr.arpa.    IN PTR  *.apps.CLUSTER.DOMINIO.

# Un registro A por nodo (etcd interno)
master-0.CLUSTER.DOMINIO. IN A   IP_NODO_0
master-1.CLUSTER.DOMINIO. IN A   IP_NODO_1
master-2.CLUSTER.DOMINIO. IN A   IP_NODO_2

# SRV records para etcd (requeridos en HA)
_etcd-server-ssl._tcp.CLUSTER.DOMINIO. IN SRV 0 10 2380 master-0.CLUSTER.DOMINIO.
_etcd-server-ssl._tcp.CLUSTER.DOMINIO. IN SRV 0 10 2380 master-1.CLUSTER.DOMINIO.
_etcd-server-ssl._tcp.CLUSTER.DOMINIO. IN SRV 0 10 2380 master-2.CLUSTER.DOMINIO.
```

#### Para SNO (1 nodo)

```
api.CLUSTER.DOMINIO.      IN A   IP_NODO
api-int.CLUSTER.DOMINIO.  IN A   IP_NODO
*.apps.CLUSTER.DOMINIO.   IN A   IP_NODO
master-0.CLUSTER.DOMINIO. IN A   IP_NODO
X.X.X.X.in-addr.arpa.    IN PTR  master-0.CLUSTER.DOMINIO.
```

#### Alternativa rápida con /etc/hosts (si no tenés DNS interno)

```bash
# En el servidor 172.18.194.190 y en cada nodo del cluster:
echo 'API_VIP     api.CLUSTER.DOMINIO api-int.CLUSTER.DOMINIO' >> /etc/hosts
echo 'INGRESS_VIP console-openshift-console.apps.CLUSTER.DOMINIO' >> /etc/hosts
echo 'INGRESS_VIP oauth-openshift.apps.CLUSTER.DOMINIO' >> /etc/hosts
```

### Qué genera el script

```
/root/OC-Mirror/cluster-output/NOMBRE-CLUSTER/
├── install-config.yaml      ← config principal del cluster
├── install-config.yaml.bak  ← backup (openshift-install consume el original)
├── agent-config.yaml        ← config de nodos (MACs, IPs, roles)
├── agent-config.yaml.bak    ← backup
├── agent.x86_64.iso         ← ISO para bootear las VMs
├── iso-generate.log         ← log de la generacion
└── auth/
    ├── kubeconfig           ← disponible tras instalacion exitosa
    └── kubeadmin-password   ← password del usuario admin
```

### Después de generar la ISO

```bash
# 1. Montar la ISO en la/s VM/s y bootear

# 2. Monitorear el proceso de instalacion
openshift-install agent wait-for bootstrap-complete \
  --dir /root/OC-Mirror/cluster-output/NOMBRE-CLUSTER

openshift-install agent wait-for install-complete \
  --dir /root/OC-Mirror/cluster-output/NOMBRE-CLUSTER

# 3. Acceder al cluster
export KUBECONFIG=/root/OC-Mirror/cluster-output/NOMBRE-CLUSTER/auth/kubeconfig
oc get nodes
oc get co    # cluster operators

# 4. Password de kubeadmin
cat /root/OC-Mirror/cluster-output/NOMBRE-CLUSTER/auth/kubeadmin-password
```

### Qué debe estar corriendo en el servidor antes de bootear las VMs

```bash
# Verificar contenedores activos
podman ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

# Si alguno está caído, levantarlo
podman start local-registry
podman start postgres
podman start assisted-installer-local
podman start assisted-installer-ui

# Verificar que el registry responde
curl -s http://172.18.194.190:5000/v2/_catalog | python3 -m json.tool

# Verificar puertos de firewall
firewall-cmd --list-ports
# Deben estar: 5000/tcp 8080/tcp 8090/tcp 9443/tcp
```
