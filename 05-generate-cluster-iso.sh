#!/bin/bash
# =============================================================
# 05-generate-cluster-iso.sh
# Wizard interactivo para generar ISO(s) de instalacion OCP
# con Agent Based Installer usando el registry local mirror.
#
# Soporta: 1 nodo (SNO) o 3 nodos (HA)
# Uso: bash /root/OC-Mirror/05-generate-cluster-iso.sh
# =============================================================
set -euo pipefail

# ── Colores ──────────────────────────────────────────────────
RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[1;33m'
BLU='\033[0;34m'; CYN='\033[0;36m'; WHT='\033[1;37m'; NC='\033[0m'
BOLD='\033[1m'

WORK_DIR="/root/OC-Mirror"
REGISTRY="172.18.194.190:5000"
PULL_SECRET_FILE="/root/pull-secret.json"
OCP_VERSION="4.15.0"
OUTPUT_DIR="${WORK_DIR}/cluster-output"

# ── Helpers ──────────────────────────────────────────────────
banner() {
  echo ""
  echo -e "${BLU}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BLU}${BOLD}║${NC}  ${WHT}${BOLD}$1${NC}"
  echo -e "${BLU}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
  echo ""
}

step() {
  echo -e "\n${CYN}${BOLD}▶ $1${NC}"
}

ok()   { echo -e "  ${GRN}✓${NC} $1"; }
warn() { echo -e "  ${YEL}⚠${NC}  $1"; }
err()  { echo -e "  ${RED}✗${NC} $1"; }
info() { echo -e "  ${WHT}→${NC} $1"; }

ask() {
  # ask "Pregunta" "default"
  local prompt="$1"
  local default="${2:-}"
  if [ -n "$default" ]; then
    echo -ne "  ${WHT}${prompt}${NC} ${YEL}[${default}]${NC}: "
  else
    echo -ne "  ${WHT}${prompt}${NC}: "
  fi
  read -r val
  if [ -z "$val" ] && [ -n "$default" ]; then
    val="$default"
  fi
  echo "$val"
}

ask_secret() {
  local prompt="$1"
  echo -ne "  ${WHT}${prompt}${NC}: "
  read -rs val
  echo ""
  echo "$val"
}

confirm() {
  echo -ne "  ${WHT}$1${NC} ${YEL}[s/N]${NC}: "
  read -r yn
  [[ "$yn" =~ ^[sS]$ ]]
}

validate_ip() {
  local ip="$1"
  if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    IFS='.' read -ra parts <<< "$ip"
    for p in "${parts[@]}"; do [ "$p" -le 255 ] || return 1; done
    return 0
  fi
  return 1
}

validate_mac() {
  [[ "$1" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]
}

validate_cidr() {
  local cidr="$1"
  local ip="${cidr%/*}"
  local mask="${cidr#*/}"
  validate_ip "$ip" && [ "$mask" -ge 0 ] && [ "$mask" -le 32 ] 2>/dev/null
}

ask_ip() {
  local prompt="$1"; local default="${2:-}"
  local val
  while true; do
    val=$(ask "$prompt" "$default")
    if validate_ip "$val"; then echo "$val"; return; fi
    err "IP invalida: $val — formato esperado: x.x.x.x"
  done
}

ask_mac() {
  local prompt="$1"
  local val
  while true; do
    val=$(ask "$prompt")
    val="${val^^}"  # uppercase
    if validate_mac "$val"; then echo "$val"; return; fi
    err "MAC invalida: $val — formato esperado: AA:BB:CC:DD:EE:FF"
  done
}

ask_cidr() {
  local prompt="$1"; local default="${2:-}"
  local val
  while true; do
    val=$(ask "$prompt" "$default")
    if validate_cidr "$val"; then echo "$val"; return; fi
    err "CIDR invalido: $val — formato esperado: x.x.x.x/24"
  done
}

# ──────────────────────────────────────────────────────────────
# INICIO
# ──────────────────────────────────────────────────────────────
clear
echo ""
echo -e "${RED}${BOLD}"
echo "  ██████╗  ██████╗██████╗     ██╗    ██╗██╗███████╗ █████╗ ██████╗ ██████╗ "
echo "  ██╔═══██╗██╔════╝██╔══██╗    ██║    ██║██║╚══███╔╝██╔══██╗██╔══██╗██╔══██╗"
echo "  ██║   ██║██║     ██████╔╝    ██║ █╗ ██║██║  ███╔╝ ███████║██████╔╝██║  ██║"
echo "  ██║   ██║██║     ██╔═══╝     ██║███╗██║██║ ███╔╝  ██╔══██║██╔══██╗██║  ██║"
echo "  ╚██████╔╝╚██████╗██║         ╚███╔███╔╝██║███████╗██║  ██║██║  ██║██████╔╝"
echo "   ╚═════╝  ╚═════╝╚═╝          ╚══╝╚══╝ ╚═╝╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝╚═════╝ "
echo -e "${NC}"
echo -e "${WHT}${BOLD}   Generador de ISO para Agent Based Installer — OCP ${OCP_VERSION}${NC}"
echo -e "${CYN}   Registry local: http://${REGISTRY}${NC}"
echo ""
echo -e "${YEL}   Este wizard genera install-config.yaml, agent-config.yaml${NC}"
echo -e "${YEL}   y la ISO de instalacion para 1 o 3 nodos (SNO o HA).${NC}"
echo ""

# ──────────────────────────────────────────────────────────────
# PASO 1: PREREQUISITOS
# ──────────────────────────────────────────────────────────────
banner "PASO 1 de 7 — Verificando prerequisitos"

PREREQ_OK=true

step "Verificando openshift-install..."
if command -v openshift-install &>/dev/null; then
  VER=$(openshift-install version 2>/dev/null | head -1 || echo "instalado")
  ok "openshift-install: $VER"
else
  err "openshift-install no encontrado en PATH"
  info "Instalalo: tar xzf openshift-install-linux.tar.gz && mv openshift-install /usr/local/bin/"
  PREREQ_OK=false
fi

step "Verificando oc CLI..."
if command -v oc &>/dev/null; then
  ok "oc: $(oc version --client 2>/dev/null | head -1)"
else
  warn "oc no encontrado — no es critico para generar la ISO"
fi

step "Verificando pull-secret..."
if [ -f "$PULL_SECRET_FILE" ]; then
  ok "Pull secret: $PULL_SECRET_FILE"
else
  err "No se encontro $PULL_SECRET_FILE"
  PREREQ_OK=false
fi

step "Verificando registry local..."
if curl -s --max-time 5 "http://${REGISTRY}/v2/" | grep -q "{}"; then
  REPO_COUNT=$(curl -s "http://${REGISTRY}/v2/_catalog" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('repositories',[])))" 2>/dev/null || echo "?")
  ok "Registry OK — ${REPO_COUNT} repositorios"
else
  err "Registry local no responde en http://${REGISTRY}"
  warn "Verificar: podman ps | grep local-registry"
  PREREQ_OK=false
fi

step "Verificando ICSP/imageset generado..."
ICSP_FILE=$(find "${WORK_DIR}/oc-mirror-workspace" -name "imageContentSourcePolicy*.yaml" 2>/dev/null | sort | tail -1)
if [ -z "$ICSP_FILE" ]; then
  ICSP_FILE=$(find "${WORK_DIR}" -name "mirror-config-para-UI.yaml" 2>/dev/null | head -1)
fi
if [ -n "$ICSP_FILE" ]; then
  ok "ICSP encontrado: $ICSP_FILE"
else
  warn "No se encontro ICSP. El cluster podria no resolver imagenes del mirror."
  warn "Ejecutar primero: bash ${WORK_DIR}/02-run-mirror.sh"
fi

if [ "$PREREQ_OK" = false ]; then
  echo ""
  err "Hay prerequisitos faltantes. Resolver antes de continuar."
  exit 1
fi

echo ""
ok "Todos los prerequisitos OK"
echo ""
read -rp "  Presiona ENTER para continuar..."

# ──────────────────────────────────────────────────────────────
# PASO 2: TOPOLOGIA DEL CLUSTER
# ──────────────────────────────────────────────────────────────
banner "PASO 2 de 7 — Topologia del Cluster"

echo -e "  ${WHT}Selecciona el tipo de cluster:${NC}"
echo ""
echo -e "  ${YEL}1)${NC} ${BOLD}SNO — Single Node OpenShift${NC} (1 VM: etcd + control plane + worker)"
echo -e "     ${MID:-}Ideal para labs, desarrollo, recursos limitados"
echo ""
echo -e "  ${YEL}3)${NC} ${BOLD}HA — High Availability${NC} (3 VMs: 3x control plane + etcd)"
echo -e "     ${MID:-}Produccion, cada nodo actua tambien como worker"
echo ""

while true; do
  echo -ne "  ${WHT}Cantidad de nodos [1/3]${NC}: "
  read -r NODE_COUNT
  case "$NODE_COUNT" in
    1) CLUSTER_TYPE="SNO";  break ;;
    3) CLUSTER_TYPE="HA";   break ;;
    *) err "Ingresar 1 o 3" ;;
  esac
done

ok "Topologia: ${BOLD}${CLUSTER_TYPE}${NC} — ${NODE_COUNT} nodo(s)"

if [ "$NODE_COUNT" -eq 1 ]; then
  info "SNO: la unica VM cumple roles de etcd, control-plane y worker."
  info "Genera UNA sola ISO."
else
  info "HA: 3 VMs, cada una es control-plane+etcd. Tambien pueden schedulear workloads."
  info "Genera UNA ISO unica — todos los nodos arrancan desde la misma ISO."
  info "La diferencia entre nodos se hace por MAC address en agent-config.yaml."
fi

echo ""
read -rp "  Presiona ENTER para continuar..."

# ──────────────────────────────────────────────────────────────
# PASO 3: DATOS DEL CLUSTER
# ──────────────────────────────────────────────────────────────
banner "PASO 3 de 7 — Datos del Cluster"

step "Identificacion del cluster"
CLUSTER_NAME=$(ask "Nombre del cluster" "ocp-xdc")
BASE_DOMAIN=$(ask "Dominio base" "empresa.local")
info "API URL sera: api.${CLUSTER_NAME}.${BASE_DOMAIN}"
info "Ingress URL: *.apps.${CLUSTER_NAME}.${BASE_DOMAIN}"

step "Red del cluster"
MACHINE_CIDR=$(ask_cidr "CIDR de la red de maquinas (donde viven las VMs)" "172.18.194.0/24")
CLUSTER_NET=$(ask_cidr "CIDR de red interna del cluster (pod network)" "10.128.0.0/14")
SERVICE_NET=$(ask_cidr "CIDR de red de servicios" "172.30.0.0/16")

step "VIPs (IPs virtuales — deben estar libres en la red)"
if [ "$NODE_COUNT" -eq 1 ]; then
  # En SNO el VIP es la IP del nodo
  info "En SNO los VIPs coinciden con la IP del nodo (se configuran despues)"
  API_VIP=""
  INGRESS_VIP=""
else
  API_VIP=$(ask_ip "VIP para la API (libre en ${MACHINE_CIDR})" "172.18.194.100")
  INGRESS_VIP=$(ask_ip "VIP para el Ingress/Apps (libre en ${MACHINE_CIDR})" "172.18.194.101")
  ok "API VIP:    ${API_VIP}"
  ok "Ingress VIP: ${INGRESS_VIP}"
fi

step "DNS y NTP"
DNS_SERVER=$(ask_ip "Servidor DNS primario" "172.18.194.1")
NTP_SERVER=$(ask "Servidor NTP" "pool.ntp.org")

step "SSH — clave publica para acceso a los nodos"
if [ -f ~/.ssh/id_rsa.pub ]; then
  SSH_KEY_DEFAULT=$(cat ~/.ssh/id_rsa.pub)
  info "Se encontro clave SSH en ~/.ssh/id_rsa.pub"
  if confirm "Usar esta clave?"; then
    SSH_KEY="$SSH_KEY_DEFAULT"
  else
    SSH_KEY=$(ask "Pegar clave SSH publica completa")
  fi
else
  warn "No se encontro ~/.ssh/id_rsa.pub"
  info "Para generar una: ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N ''"
  SSH_KEY=$(ask "Pegar clave SSH publica completa (o ENTER para omitir)")
fi

echo ""
read -rp "  Presiona ENTER para continuar..."

# ──────────────────────────────────────────────────────────────
# PASO 4: DATOS DE LOS NODOS
# ──────────────────────────────────────────────────────────────
banner "PASO 4 de 7 — Configuracion de los Nodos"

declare -a NODE_NAMES=()
declare -a NODE_MACS=()
declare -a NODE_IPS=()
declare -a NODE_IFACES=()
declare -a NODE_ROLES=()

collect_node() {
  local idx=$1
  local role=$2
  local name

  if [ "$NODE_COUNT" -eq 1 ]; then
    name="master-0"
  else
    name="master-${idx}"
  fi

  echo ""
  echo -e "  ${YEL}${BOLD}── Nodo $((idx+1)) de ${NODE_COUNT}: ${name} (${role}) ──${NC}"

  local mac ip iface
  mac=$(ask_mac   "  MAC address de la VM ${name}")
  ip=$(ask_ip     "  IP estatica del nodo ${name}" "172.18.194.$((10+idx))")
  iface=$(ask     "  Interfaz de red de la VM" "ens3")

  NODE_NAMES+=("$name")
  NODE_MACS+=("$mac")
  NODE_IPS+=("$ip")
  NODE_IFACES+=("$iface")
  NODE_ROLES+=("$role")

  ok "Nodo ${name}: MAC=${mac}  IP=${ip}  iface=${iface}  rol=${role}"
}

if [ "$NODE_COUNT" -eq 1 ]; then
  collect_node 0 "master"
  # En SNO el VIP = IP del nodo
  API_VIP="${NODE_IPS[0]}"
  INGRESS_VIP="${NODE_IPS[0]}"
  info "SNO: API VIP e Ingress VIP = ${API_VIP}"
else
  for i in 0 1 2; do
    collect_node "$i" "master"
  done
fi

step "Prefijo de red (mascara para IPs estaticas)"
NET_PREFIX=$(ask "Prefijo de red" "24")

echo ""
read -rp "  Presiona ENTER para continuar..."

# ──────────────────────────────────────────────────────────────
# PASO 5: CONFIGURACION DEL MIRROR
# ──────────────────────────────────────────────────────────────
banner "PASO 5 de 7 — Configuracion del Registry Mirror"

step "Registry local"
info "Registry: http://${REGISTRY}"
info "Las imagenes de OCP se sirven desde el registry mirror local."
info "El cluster NO necesitara acceso a internet durante la instalacion."

# Leer el ICSP generado por oc-mirror
MIRROR_REGISTRIES=""
if [ -n "$ICSP_FILE" ] && [ -f "$ICSP_FILE" ]; then
  ok "Usando ICSP: $ICSP_FILE"
  # Extraer las entradas mirrors del ICSP para usarlas en install-config
  MIRROR_REGISTRIES=$(python3 << PYEOF
import yaml, sys
try:
    with open("${ICSP_FILE}") as f:
        doc = yaml.safe_load(f)
    entries = doc.get("spec", {}).get("repositoryDigestMirrors", [])
    lines = []
    for e in entries:
        source  = e.get("source", "")
        mirrors = e.get("mirrors", [])
        if source and mirrors:
            lines.append(f"  - source: {source}")
            lines.append(f"    mirrors:")
            for m in mirrors:
                lines.append(f"    - {m}")
    print('\n'.join(lines))
except Exception as ex:
    print(f"  # Error leyendo ICSP: {ex}")
PYEOF
)
else
  warn "Sin ICSP — usando configuracion generica del registry local"
  MIRROR_REGISTRIES="  - source: quay.io/openshift-release-dev/ocp-release
    mirrors:
    - ${REGISTRY}/openshift/release-images
  - source: quay.io/openshift-release-dev/ocp-v4.0-art-dev
    mirrors:
    - ${REGISTRY}/openshift/release"
fi

# Certificado CA del registry (si usa TLS)
REGISTRY_CA=""
if confirm "  El registry usa TLS con certificado custom? (no = HTTP plain)"; then
  CERT_PATH=$(ask "  Ruta al certificado CA del registry" "/opt/registry/certs/ca.crt")
  if [ -f "$CERT_PATH" ]; then
    REGISTRY_CA=$(cat "$CERT_PATH" | sed 's/^/      /')
    ok "Certificado CA cargado"
  else
    err "Archivo no encontrado: $CERT_PATH"
    REGISTRY_CA=""
  fi
else
  ok "Registry HTTP sin TLS — no se requiere CA"
fi

echo ""
read -rp "  Presiona ENTER para continuar..."

# ──────────────────────────────────────────────────────────────
# PASO 6: RESUMEN Y CONFIRMACION
# ──────────────────────────────────────────────────────────────
banner "PASO 6 de 7 — Resumen de Configuracion"

echo -e "  ${WHT}${BOLD}CLUSTER${NC}"
echo -e "  Nombre:        ${GRN}${CLUSTER_NAME}.${BASE_DOMAIN}${NC}"
echo -e "  Topologia:     ${GRN}${CLUSTER_TYPE} (${NODE_COUNT} nodo/s)${NC}"
echo -e "  OCP Version:   ${GRN}${OCP_VERSION}${NC}"
echo -e "  API VIP:       ${GRN}${API_VIP}${NC}"
echo -e "  Ingress VIP:   ${GRN}${INGRESS_VIP}${NC}"
echo -e "  Machine CIDR:  ${GRN}${MACHINE_CIDR}${NC}"
echo -e "  Cluster Net:   ${GRN}${CLUSTER_NET}${NC}"
echo -e "  Service Net:   ${GRN}${SERVICE_NET}${NC}"
echo -e "  DNS:           ${GRN}${DNS_SERVER}${NC}"
echo -e "  NTP:           ${GRN}${NTP_SERVER}${NC}"
echo ""
echo -e "  ${WHT}${BOLD}NODOS${NC}"
for i in "${!NODE_NAMES[@]}"; do
  echo -e "  ${YEL}${NODE_NAMES[$i]}${NC}  MAC: ${GRN}${NODE_MACS[$i]}${NC}  IP: ${GRN}${NODE_IPS[$i]}${NC}  iface: ${GRN}${NODE_IFACES[$i]}${NC}  rol: ${GRN}${NODE_ROLES[$i]}${NC}"
done
echo ""
echo -e "  ${WHT}${BOLD}REGISTRY${NC}"
echo -e "  Mirror: ${GRN}http://${REGISTRY}${NC}"
echo -e "  ICSP:   ${GRN}${ICSP_FILE:-generica}${NC}"
echo ""

if ! confirm "Confirmar y generar ISO?"; then
  warn "Cancelado por el usuario."
  exit 0
fi

# ──────────────────────────────────────────────────────────────
# PASO 7: GENERACION DE ARCHIVOS E ISO
# ──────────────────────────────────────────────────────────────
banner "PASO 7 de 7 — Generando ISO"

CLUSTER_DIR="${OUTPUT_DIR}/${CLUSTER_NAME}"
mkdir -p "${CLUSTER_DIR}"
step "Directorio de trabajo: ${CLUSTER_DIR}"

# ── Leer pull-secret ──────────────────────────────────────────
PULL_SECRET_RAW=$(cat "$PULL_SECRET_FILE")

# Agregar entrada del registry local al pull-secret
LOCAL_AUTH=$(echo -n "unused:unused" | base64 -w0)
PULL_SECRET_MERGED=$(echo "$PULL_SECRET_RAW" | python3 -c "
import sys, json
ps = json.load(sys.stdin)
ps['auths']['${REGISTRY}'] = {'auth': '${LOCAL_AUTH}', 'email': 'local@local'}
print(json.dumps(ps))
")

# ── install-config.yaml ───────────────────────────────────────
step "Generando install-config.yaml..."

# Construir seccion additionalTrustBundle
if [ -n "$REGISTRY_CA" ]; then
  TRUST_BUNDLE="additionalTrustBundle: |
${REGISTRY_CA}"
else
  TRUST_BUNDLE=""
fi

# Construir imageContentSources desde ICSP
ICS_SECTION=""
if [ -n "$MIRROR_REGISTRIES" ]; then
  ICS_SECTION="imageContentSources:
${MIRROR_REGISTRIES}"
fi

cat > "${CLUSTER_DIR}/install-config.yaml" << YAML
apiVersion: v1
baseDomain: ${BASE_DOMAIN}
metadata:
  name: ${CLUSTER_NAME}
compute:
  - name: worker
    replicas: 0
controlPlane:
  name: master
  replicas: ${NODE_COUNT}
  platform: {}
networking:
  clusterNetwork:
    - cidr: ${CLUSTER_NET}
      hostPrefix: 23
  machineNetwork:
    - cidr: ${MACHINE_CIDR}
  networkType: OVNKubernetes
  serviceNetwork:
    - ${SERVICE_NET}
platform:
  none: {}
pullSecret: '${PULL_SECRET_MERGED}'
sshKey: '${SSH_KEY}'
${TRUST_BUNDLE}
${ICS_SECTION}
YAML

ok "install-config.yaml generado"

# ── agent-config.yaml ─────────────────────────────────────────
step "Generando agent-config.yaml..."

# Construir seccion de hosts dinamicamente
HOSTS_YAML=""
for i in "${!NODE_NAMES[@]}"; do
  name="${NODE_NAMES[$i]}"
  mac="${NODE_MACS[$i]}"
  ip="${NODE_IPS[$i]}"
  iface="${NODE_IFACES[$i]}"
  role="${NODE_ROLES[$i]}"

  HOSTS_YAML+="  - hostname: ${name}
    role: ${role}
    interfaces:
      - name: ${iface}
        macAddress: ${mac}
    networkConfig:
      interfaces:
        - name: ${iface}
          type: ethernet
          state: up
          macAddress: ${mac}
          ipv4:
            enabled: true
            address:
              - ip: ${ip}
                prefix-length: ${NET_PREFIX}
            dhcp: false
      dns-resolver:
        config:
          server:
            - ${DNS_SERVER}
      routes:
        config:
          - destination: 0.0.0.0/0
            next-hop-address: $(echo "$MACHINE_CIDR" | awk -F'[./]' '{print $1"."$2"."$3".1"}')
            next-hop-interface: ${iface}
            table-id: 254
"
done

# VIPs para HA
if [ "$NODE_COUNT" -eq 3 ]; then
  VIP_SECTION="  apiVIPs:
    - ${API_VIP}
  ingressVIPs:
    - ${INGRESS_VIP}"
else
  VIP_SECTION="  apiVIPs:
    - ${API_VIP}
  ingressVIPs:
    - ${INGRESS_VIP}"
fi

cat > "${CLUSTER_DIR}/agent-config.yaml" << YAML
apiVersion: v1alpha1
kind: AgentConfig
metadata:
  name: ${CLUSTER_NAME}
rendezvousIP: ${NODE_IPS[0]}
additionalNTPSources:
  - ${NTP_SERVER}
hosts:
${HOSTS_YAML}
YAML

ok "agent-config.yaml generado"

# ── Agregar VIPs al install-config si es HA ───────────────────
if [ "$NODE_COUNT" -eq 3 ]; then
  python3 << PYEOF
import yaml
with open("${CLUSTER_DIR}/install-config.yaml") as f:
    content = f.read()
# Insertar VIPs en la seccion platform
content = content.replace("platform:\n  none: {}",
    "platform:\n  baremetal:\n    apiVIPs:\n      - ${API_VIP}\n    ingressVIPs:\n      - ${INGRESS_VIP}")
with open("${CLUSTER_DIR}/install-config.yaml", "w") as f:
    f.write(content)
PYEOF
  ok "VIPs agregados al install-config.yaml (modo baremetal/none)"
fi

# ── Mostrar archivos generados ────────────────────────────────
step "Archivos generados:"
echo ""
echo -e "  ${GRN}${CLUSTER_DIR}/install-config.yaml${NC}"
echo -e "  ${GRN}${CLUSTER_DIR}/agent-config.yaml${NC}"

# ── Generar la ISO ────────────────────────────────────────────
step "Ejecutando openshift-install agent create image..."
echo ""

cd "${CLUSTER_DIR}"

# Backup de los configs (openshift-install los consume y borra)
cp install-config.yaml install-config.yaml.bak
cp agent-config.yaml   agent-config.yaml.bak

openshift-install agent create image \
  --dir "${CLUSTER_DIR}" \
  --log-level info \
  2>&1 | tee "${CLUSTER_DIR}/iso-generate.log"

ISO_FILE=$(find "${CLUSTER_DIR}" -name "agent.x86_64.iso" -o -name "*.iso" 2>/dev/null | head -1)

echo ""
if [ -n "$ISO_FILE" ] && [ -f "$ISO_FILE" ]; then
  ISO_SIZE=$(du -sh "$ISO_FILE" | cut -f1)
  echo -e "${GRN}${BOLD}"
  echo "  ╔══════════════════════════════════════════════════════════╗"
  echo "  ║                   ISO GENERADA CON EXITO                ║"
  echo "  ╚══════════════════════════════════════════════════════════╝"
  echo -e "${NC}"
  ok "ISO: ${ISO_FILE}"
  ok "Tamano: ${ISO_SIZE}"
  echo ""
  echo -e "  ${WHT}${BOLD}Proximos pasos:${NC}"
  echo ""
  if [ "$NODE_COUNT" -eq 1 ]; then
    echo -e "  ${YEL}1)${NC} Montar la ISO en la VM ${NODE_NAMES[0]} (${NODE_IPS[0]})"
    echo -e "  ${YEL}2)${NC} Bootear la VM desde la ISO"
    echo -e "  ${YEL}3)${NC} Monitorear: openshift-install agent wait-for bootstrap-complete --dir ${CLUSTER_DIR}"
    echo -e "  ${YEL}4)${NC} Monitorear: openshift-install agent wait-for install-complete  --dir ${CLUSTER_DIR}"
  else
    echo -e "  ${YEL}1)${NC} Montar la MISMA ISO en las 3 VMs:"
    for i in "${!NODE_NAMES[@]}"; do
      echo -e "     ${GRN}${NODE_NAMES[$i]}${NC} — MAC: ${NODE_MACS[$i]} — IP: ${NODE_IPS[$i]}"
    done
    echo ""
    echo -e "  ${YEL}2)${NC} Bootear las 3 VMs desde la ISO (pueden arrancar en cualquier orden)"
    echo -e "  ${YEL}3)${NC} Monitorear instalacion:"
    echo -e "     ${CYN}openshift-install agent wait-for bootstrap-complete --dir ${CLUSTER_DIR}${NC}"
    echo -e "     ${CYN}openshift-install agent wait-for install-complete   --dir ${CLUSTER_DIR}${NC}"
    echo ""
    echo -e "  ${YEL}4)${NC} Agregar DNS records:"
    echo -e "     api.${CLUSTER_NAME}.${BASE_DOMAIN}     -> ${API_VIP}"
    echo -e "     *.apps.${CLUSTER_NAME}.${BASE_DOMAIN}  -> ${INGRESS_VIP}"
  fi
  echo ""
  echo -e "  ${YEL}5)${NC} Obtener kubeconfig:"
  echo -e "     ${CYN}export KUBECONFIG=${CLUSTER_DIR}/auth/kubeconfig${NC}"
  echo -e "     ${CYN}oc get nodes${NC}"
  echo ""
  echo -e "  ${YEL}6)${NC} Obtener password de kubeadmin:"
  echo -e "     ${CYN}cat ${CLUSTER_DIR}/auth/kubeadmin-password${NC}"
else
  err "No se encontro la ISO generada."
  warn "Revisar log: ${CLUSTER_DIR}/iso-generate.log"
  warn "Verificar que openshift-install sea version ${OCP_VERSION}"
  echo ""
  echo -e "  ${WHT}Intento manual:${NC}"
  echo -e "  ${CYN}cd ${CLUSTER_DIR}${NC}"
  echo -e "  ${CYN}cp install-config.yaml.bak install-config.yaml${NC}"
  echo -e "  ${CYN}cp agent-config.yaml.bak   agent-config.yaml${NC}"
  echo -e "  ${CYN}openshift-install agent create image --dir . --log-level debug${NC}"
fi

echo ""
echo -e "  ${CYN}Directorio del cluster: ${CLUSTER_DIR}${NC}"
echo -e "  ${CYN}Logs: ${CLUSTER_DIR}/iso-generate.log${NC}"
echo ""
