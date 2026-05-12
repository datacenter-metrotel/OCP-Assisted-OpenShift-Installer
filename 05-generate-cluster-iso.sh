#!/bin/bash
# =============================================================
# 05-generate-cluster-iso.sh
# Wizard para generar ISO de instalacion OCP con Agent Based Installer
# Uso: bash /root/OC-Mirror/05-generate-cluster-iso.sh
# =============================================================
set -euo pipefail

WORK_DIR="/root/OC-Mirror"
REGISTRY="172.18.194.190:5000"
PULL_SECRET_FILE="/root/pull-secret.json"
OCP_VERSION="4.15.0"
OUTPUT_DIR="${WORK_DIR}/cluster-output"

# Colores solo para echo -e decorativo, nunca en prompts de read
R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m'
B='\033[0;34m' C='\033[0;36m' W='\033[1;37m' D='\033[2m' N='\033[0m' BOLD='\033[1m'

banner() {
  echo ""
  echo -e "${B}${BOLD}╔══════════════════════════════════════════════════════════╗${N}"
  echo -e "${B}${BOLD}║  ${W}${BOLD}$1${N}"
  echo -e "${B}${BOLD}╚══════════════════════════════════════════════════════════╝${N}"
  echo ""
}
step()  { echo ""; echo -e "${C}${BOLD}▶ $1${N}"; echo ""; }
ok()    { echo -e "  ${G}OK${N}  $1"; }
warn()  { echo -e "  ${Y}WARN${N} $1"; }
err()   { echo -e "  ${R}ERR${N} $1"; }
info()  { echo -e "  ->  $1"; }
ej()    { echo -e "  ${D}    Ej: $1${N}"; }
sep()   { echo -e "  ${D}  ────────────────────────────────────${N}"; }
ask_enter() { echo ""; echo -n "  Presiona ENTER para continuar..."; read -r _DUMMY; }

validate_ip() {
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -ra _p <<< "$1"
  for p in "${_p[@]}"; do [ "$p" -le 255 ] 2>/dev/null || return 1; done
}
validate_mac() { [[ "${1^^}" =~ ^([0-9A-F]{2}:){5}[0-9A-F]{2}$ ]]; }
validate_cidr() {
  local ip="${1%/*}" mask="${1#*/}"
  validate_ip "$ip" && [[ "$mask" =~ ^[0-9]+$ ]] && [ "$mask" -ge 0 ] && [ "$mask" -le 32 ]
}

# ──────────────────────────────────────────────────────────────
clear
echo ""
echo -e "${R}${BOLD}  OCP Wizard — Agent Based Installer — ${OCP_VERSION}${N}"
echo -e "${C}  Registry: http://${REGISTRY}${N}"
echo ""

# ──────────────────────────────────────────────────────────────
# PASO 1 — PREREQUISITOS
# ──────────────────────────────────────────────────────────────
banner "PASO 1 de 7 — Verificando prerequisitos"
PREREQ_OK=true

command -v openshift-install &>/dev/null \
  && ok "openshift-install: $(openshift-install version 2>/dev/null | head -1)" \
  || { err "openshift-install no encontrado"; PREREQ_OK=false; }

[ -f "$PULL_SECRET_FILE" ] \
  && ok "Pull secret: $PULL_SECRET_FILE" \
  || { err "No se encontro $PULL_SECRET_FILE"; PREREQ_OK=false; }

curl -s --max-time 5 "http://${REGISTRY}/v2/" | grep -q "{}" \
  && ok "Registry: http://${REGISTRY}" \
  || { err "Registry no responde en http://${REGISTRY}"; PREREQ_OK=false; }

ICSP_FILE=$(find "${WORK_DIR}/oc-mirror-workspace" -name "imageContentSourcePolicy*.yaml" 2>/dev/null | sort | tail -1)
[ -z "$ICSP_FILE" ] && ICSP_FILE=$(find "${WORK_DIR}" -name "mirror-config-para-UI.yaml" 2>/dev/null | head -1)
[ -n "$ICSP_FILE" ] && ok "ICSP: $ICSP_FILE" || warn "Sin ICSP — ejecutar 02-run-mirror.sh primero"

[ "$PREREQ_OK" = false ] && { echo ""; err "Prerequisitos faltantes. Resolver antes de continuar."; exit 1; }
echo ""; ok "Todo OK"
ask_enter

# ──────────────────────────────────────────────────────────────
# PASO 2 — TOPOLOGIA
# ──────────────────────────────────────────────────────────────
banner "PASO 2 de 7 — Topologia del Cluster"

echo -e "  ${W}${BOLD}Tipo de cluster:${N}"
echo ""
echo "  1)  SNO — Single Node OpenShift"
echo "        1 VM: etcd + control plane + worker"
echo "        Ideal para labs, desarrollo, recursos limitados"
echo ""
echo "  3)  HA — High Availability"
echo "        3 VMs: control plane + etcd en cada una"
echo "        Produccion. Los nodos tambien schedulean workloads"
echo ""

while true; do
  echo -n "  Cantidad de nodos [1 = SNO  /  3 = HA]: "
  read -r NODE_COUNT
  case "$NODE_COUNT" in
    1) CLUSTER_TYPE="SNO"; break ;;
    3) CLUSTER_TYPE="HA";  break ;;
    *) echo "  -> Ingresar 1 o 3" ;;
  esac
done

echo ""
ok "Topologia: ${CLUSTER_TYPE} — ${NODE_COUNT} nodo(s)"
[ "$NODE_COUNT" -eq 1 ] \
  && info "Una sola ISO. La VM se configura sola al bootear." \
  || info "Una sola ISO para las 3 VMs. Cada una se identifica por MAC address."
ask_enter

# ──────────────────────────────────────────────────────────────
# PASO 3 — DATOS DEL CLUSTER
# ──────────────────────────────────────────────────────────────
banner "PASO 3 de 7 — Datos del Cluster"

# ── Nombre y dominio ──────────────────────────────────────────
step "Identificacion del cluster"
echo "  El nombre + dominio forman el FQDN completo del cluster."
echo ""
ej "Nombre: ocp-upstream   Dominio: metrotel.xdc"
ej "  -> API:   api.ocp-upstream.metrotel.xdc"
ej "  -> Apps:  *.apps.ocp-upstream.metrotel.xdc"
sep

echo ""
echo "  Nombre del cluster:"
ej "ocp-upstream  /  ocp-prod  /  openshift-xdc"
echo -n "  Nombre: "
read -r CLUSTER_NAME
[ -z "$CLUSTER_NAME" ] && CLUSTER_NAME="ocp-upstream"

echo ""
echo "  Dominio base de la organizacion:"
ej "metrotel.xdc  /  empresa.local  /  corp.net"
echo -n "  Dominio: "
read -r BASE_DOMAIN
[ -z "$BASE_DOMAIN" ] && BASE_DOMAIN="metrotel.xdc"

echo ""
ok "Cluster: ${CLUSTER_NAME}.${BASE_DOMAIN}"
info "API:  api.${CLUSTER_NAME}.${BASE_DOMAIN}"
info "Apps: *.apps.${CLUSTER_NAME}.${BASE_DOMAIN}"

# ── Redes ─────────────────────────────────────────────────────
step "Redes del cluster"
echo "  Machine CIDR: red donde viven las VMs."
echo "  Cluster Net:  red interna de pods (no debe superponerse con la de VMs)."
echo "  Service Net:  red interna de servicios Kubernetes."
sep

echo ""
echo "  Red de las VMs (machine network):"
ej "172.18.194.0/24"
echo -n "  Machine CIDR [Enter = 172.18.194.0/24]: "
read -r MACHINE_CIDR
[ -z "$MACHINE_CIDR" ] && MACHINE_CIDR="172.18.194.0/24"
while ! validate_cidr "$MACHINE_CIDR"; do
  echo "  ERROR: CIDR invalido. Formato: x.x.x.x/nn"
  echo -n "  Machine CIDR: "
  read -r MACHINE_CIDR
done

echo ""
echo "  Red interna de pods:"
ej "10.128.0.0/14"
echo -n "  Cluster Network [Enter = 10.128.0.0/14]: "
read -r CLUSTER_NET
[ -z "$CLUSTER_NET" ] && CLUSTER_NET="10.128.0.0/14"

echo ""
echo "  Red interna de servicios:"
ej "172.30.0.0/16"
echo -n "  Service Network [Enter = 172.30.0.0/16]: "
read -r SERVICE_NET
[ -z "$SERVICE_NET" ] && SERVICE_NET="172.30.0.0/16"

# ── VIPs para HA ──────────────────────────────────────────────
if [ "$NODE_COUNT" -eq 3 ]; then
  step "VIPs — IPs Virtuales del cluster"
  echo "  IPs flotantes que NO deben estar asignadas a ninguna VM."
  echo "  Deben estar libres dentro de ${MACHINE_CIDR}."
  sep

  echo ""
  echo "  VIP para la API de Kubernetes:"
  ej "172.18.194.100  (libre, no usada por ninguna VM)"
  echo -n "  API VIP [Enter = 172.18.194.100]: "
  read -r API_VIP
  [ -z "$API_VIP" ] && API_VIP="172.18.194.100"
  while ! validate_ip "$API_VIP"; do
    echo "  ERROR: IP invalida."
    echo -n "  API VIP: "
    read -r API_VIP
  done

  echo ""
  echo "  VIP para el Ingress / Apps:"
  ej "172.18.194.101  (libre, diferente al API VIP)"
  echo -n "  Ingress VIP [Enter = 172.18.194.101]: "
  read -r INGRESS_VIP
  [ -z "$INGRESS_VIP" ] && INGRESS_VIP="172.18.194.101"
  while ! validate_ip "$INGRESS_VIP"; do
    echo "  ERROR: IP invalida."
    echo -n "  Ingress VIP: "
    read -r INGRESS_VIP
  done
fi

# ── DNS ───────────────────────────────────────────────────────
step "Servidores DNS"
echo "  Las VMs usaran estos DNS durante y despues de la instalacion."
echo "  El DNS primario debe resolver api.* y *.apps.* del cluster."
sep

echo ""
echo "  DNS primario:"
ej "172.18.194.36"
echo -n "  DNS primario [Enter = 172.18.194.36]: "
read -r DNS_PRIMARY
[ -z "$DNS_PRIMARY" ] && DNS_PRIMARY="172.18.194.36"
while ! validate_ip "$DNS_PRIMARY"; do
  echo "  ERROR: IP invalida."
  echo -n "  DNS primario: "
  read -r DNS_PRIMARY
done

echo ""
echo "  DNS secundario:"
ej "172.18.194.37"
echo -n "  DNS secundario [Enter = 172.18.194.37]: "
read -r DNS_SECONDARY
[ -z "$DNS_SECONDARY" ] && DNS_SECONDARY="172.18.194.37"

# ── NTP ───────────────────────────────────────────────────────
step "Servidores NTP"
echo "  Los nodos necesitan sincronizacion de tiempo."
echo "  Usar el mismo NTP de la infraestructura."
sep

echo ""
echo "  NTP primario:"
ej "172.18.194.36"
echo -n "  NTP primario [Enter = 172.18.194.36]: "
read -r NTP_PRIMARY
[ -z "$NTP_PRIMARY" ] && NTP_PRIMARY="172.18.194.36"

echo ""
echo "  NTP secundario:"
ej "172.18.194.37"
echo -n "  NTP secundario [Enter = 172.18.194.37]: "
read -r NTP_SECONDARY
[ -z "$NTP_SECONDARY" ] && NTP_SECONDARY="172.18.194.37"

# ── SSH Key ───────────────────────────────────────────────────
step "Clave SSH para acceso a los nodos"
echo "  Se inyecta en todos los nodos. Permite 'ssh core@IP' para debug."
sep
echo ""

if [ -f ~/.ssh/id_rsa.pub ]; then
  ok "Clave encontrada en ~/.ssh/id_rsa.pub"
  echo -n "  Usar esta clave? [S/n]: "
  read -r _yn
  if [[ "$_yn" =~ ^[nN]$ ]]; then
    echo ""
    echo "  Pegar clave SSH publica completa:"
    echo -n "  SSH Key: "
    read -r SSH_KEY
  else
    SSH_KEY=$(cat ~/.ssh/id_rsa.pub)
    ok "Usando ~/.ssh/id_rsa.pub"
  fi
else
  warn "No se encontro ~/.ssh/id_rsa.pub"
  info "Para generar: ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N ''"
  echo ""
  echo "  Pegar clave SSH publica (o Enter para omitir):"
  echo -n "  SSH Key: "
  read -r SSH_KEY
fi

ask_enter

# ──────────────────────────────────────────────────────────────
# PASO 4 — NODOS
# ──────────────────────────────────────────────────────────────
banner "PASO 4 de 7 — Configuracion de los Nodos"

echo "  Por cada VM necesitamos MAC address, IP fija e interfaz de red."
echo "  La MAC identifica cada VM para asignarle hostname, IP y rol."
echo ""

declare -a NODE_NAMES=()
declare -a NODE_MACS=()
declare -a NODE_IPS=()
declare -a NODE_IFACES=()
declare -a NODE_ROLES=()

# Calcular primer octeto del CIDR para sugerir IPs
IFS='.' read -ra _NET <<< "${MACHINE_CIDR%/*}"
NET_BASE="${_NET[0]}.${_NET[1]}.${_NET[2]}"

for IDX in $(seq 0 $((NODE_COUNT-1))); do
  [ "$NODE_COUNT" -eq 1 ] && NNAME="master-0" || NNAME="master-${IDX}"

  echo ""
  echo -e "  ${Y}${BOLD}── Nodo $((IDX+1)) de ${NODE_COUNT}: ${NNAME} ──${N}"
  echo ""

  # MAC
  echo "  MAC address de la VM ${NNAME}:"
  echo "    -> Obtenerla en el hipervisor (virt-manager, vSphere, Proxmox, etc.)"
  ej "52:54:00:AB:CD:0${IDX}"
  while true; do
    echo -n "  MAC: "
    read -r _MAC
    _MAC="${_MAC^^}"
    validate_mac "$_MAC" && break
    echo "  ERROR: MAC invalida. Formato: AA:BB:CC:DD:EE:FF  (letras mayusculas o minusculas)"
  done
  NODE_MACS+=("$_MAC")

  # IP
  _DEFAULT_IP="${NET_BASE}.$((10+IDX))"
  echo ""
  echo "  IP estatica del nodo ${NNAME}:"
  ej "${_DEFAULT_IP}  (libre dentro de ${MACHINE_CIDR})"
  while true; do
    echo -n "  IP [Enter = ${_DEFAULT_IP}]: "
    read -r _IP
    [ -z "$_IP" ] && _IP="$_DEFAULT_IP"
    validate_ip "$_IP" && break
    echo "  ERROR: IP invalida. Formato: x.x.x.x"
  done
  NODE_IPS+=("$_IP")

  # Interfaz
  echo ""
  echo "  Nombre de la interfaz de red dentro de la VM:"
  ej "ens3  (KVM/QEMU)   eth0  (generico)   ens192  (VMware)"
  echo -n "  Interfaz [Enter = ens3]: "
  read -r _IFACE
  [ -z "$_IFACE" ] && _IFACE="ens3"
  NODE_IFACES+=("$_IFACE")

  NODE_NAMES+=("$NNAME")
  NODE_ROLES+=("master")

  echo ""
  ok "Nodo ${NNAME}: MAC=${_MAC}  IP=${_IP}  iface=${_IFACE}"
done

# SNO: VIPs = IP del nodo
if [ "$NODE_COUNT" -eq 1 ]; then
  API_VIP="${NODE_IPS[0]}"
  INGRESS_VIP="${NODE_IPS[0]}"
  info "SNO: API VIP e Ingress VIP = ${API_VIP}"
fi

# Gateway
step "Gateway y prefijo de red"
GW_DEFAULT="${NET_BASE}.1"
echo "  Gateway por defecto de la red ${MACHINE_CIDR}:"
ej "${GW_DEFAULT}"
while true; do
  echo -n "  Gateway [Enter = ${GW_DEFAULT}]: "
  read -r GATEWAY
  [ -z "$GATEWAY" ] && GATEWAY="$GW_DEFAULT"
  validate_ip "$GATEWAY" && break
  echo "  ERROR: IP invalida."
done

NET_PREFIX="${MACHINE_CIDR#*/}"
echo ""
info "Prefijo de red: /${NET_PREFIX}  (tomado de ${MACHINE_CIDR})"

# ── Mostrar DNS a crear ───────────────────────────────────────
echo ""
echo -e "  ${Y}${BOLD}╔══════════════════════════════════════════════════════════╗${N}"
echo -e "  ${Y}${BOLD}║    REGISTROS DNS QUE DEBES CREAR ANTES DE BOOTEAR       ║${N}"
echo -e "  ${Y}${BOLD}╚══════════════════════════════════════════════════════════╝${N}"
echo ""
echo "  Servidor DNS: ${DNS_PRIMARY}"
echo ""

if [ "$NODE_COUNT" -eq 1 ]; then
  echo "  # API e Ingress (SNO: misma IP para todo)"
  echo "  api.${CLUSTER_NAME}.${BASE_DOMAIN}.          IN A  ${API_VIP}"
  echo "  api-int.${CLUSTER_NAME}.${BASE_DOMAIN}.      IN A  ${API_VIP}"
  echo "  *.apps.${CLUSTER_NAME}.${BASE_DOMAIN}.       IN A  ${INGRESS_VIP}"
  echo "  master-0.${CLUSTER_NAME}.${BASE_DOMAIN}.     IN A  ${NODE_IPS[0]}"
  echo ""
  echo "  # /etc/hosts alternativo en este servidor:"
  echo "  echo '${API_VIP}  api.${CLUSTER_NAME}.${BASE_DOMAIN} api-int.${CLUSTER_NAME}.${BASE_DOMAIN}' >> /etc/hosts"
  echo "  echo '${API_VIP}  console-openshift-console.apps.${CLUSTER_NAME}.${BASE_DOMAIN}' >> /etc/hosts"
  echo "  echo '${API_VIP}  oauth-openshift.apps.${CLUSTER_NAME}.${BASE_DOMAIN}' >> /etc/hosts"
else
  echo "  # API e Ingress"
  echo "  api.${CLUSTER_NAME}.${BASE_DOMAIN}.          IN A  ${API_VIP}"
  echo "  api-int.${CLUSTER_NAME}.${BASE_DOMAIN}.      IN A  ${API_VIP}"
  echo "  *.apps.${CLUSTER_NAME}.${BASE_DOMAIN}.       IN A  ${INGRESS_VIP}"
  echo ""
  echo "  # Un A por nodo"
  for i in "${!NODE_NAMES[@]}"; do
    echo "  ${NODE_NAMES[$i]}.${CLUSTER_NAME}.${BASE_DOMAIN}.  IN A  ${NODE_IPS[$i]}"
  done
  echo ""
  echo "  # SRV records etcd (requeridos en HA)"
  for i in "${!NODE_NAMES[@]}"; do
    echo "  _etcd-server-ssl._tcp.${CLUSTER_NAME}.${BASE_DOMAIN}. IN SRV 0 10 2380 ${NODE_NAMES[$i]}.${CLUSTER_NAME}.${BASE_DOMAIN}."
  done
  echo ""
  echo "  # /etc/hosts alternativo:"
  echo "  echo '${API_VIP}     api.${CLUSTER_NAME}.${BASE_DOMAIN} api-int.${CLUSTER_NAME}.${BASE_DOMAIN}' >> /etc/hosts"
  echo "  echo '${INGRESS_VIP} console-openshift-console.apps.${CLUSTER_NAME}.${BASE_DOMAIN}' >> /etc/hosts"
  echo "  echo '${INGRESS_VIP} oauth-openshift.apps.${CLUSTER_NAME}.${BASE_DOMAIN}' >> /etc/hosts"
fi
echo ""
echo "  IMPORTANTE: Crear estos registros ANTES de bootear las VMs."
echo ""
echo -n "  Presiona ENTER cuando hayas anotado los registros DNS..."; read -r _DUMMY

# ──────────────────────────────────────────────────────────────
# PASO 5 — MIRROR
# ──────────────────────────────────────────────────────────────
banner "PASO 5 de 7 — Configuracion del Registry Mirror"

info "Registry: http://${REGISTRY}"
info "Las imagenes de OCP se sirven desde el registry local."
info "El cluster NO necesitara acceso a internet."
echo ""

MIRROR_REGISTRIES=""
if [ -n "$ICSP_FILE" ] && [ -f "$ICSP_FILE" ]; then
  ok "ICSP: $ICSP_FILE"
  MIRROR_REGISTRIES=$(python3 -c "
import yaml
with open('${ICSP_FILE}') as f:
    doc = yaml.safe_load(f)
entries = doc.get('spec', {}).get('repositoryDigestMirrors', [])
lines = []
for e in entries:
    src = e.get('source',''); mirrors = e.get('mirrors',[])
    if src and mirrors:
        lines.append('  - source: ' + src)
        lines.append('    mirrors:')
        for m in mirrors: lines.append('    - ' + m)
print('\n'.join(lines))
" 2>/dev/null || echo "")
else
  warn "Sin ICSP — usando configuracion generica"
  MIRROR_REGISTRIES="  - source: quay.io/openshift-release-dev/ocp-release
    mirrors:
    - ${REGISTRY}/openshift/release-images
  - source: quay.io/openshift-release-dev/ocp-v4.0-art-dev
    mirrors:
    - ${REGISTRY}/openshift/release"
fi

REGISTRY_CA=""
echo -n "  El registry usa TLS con certificado propio? (responder n si es HTTP) [s/N]: "
read -r _yn
if [[ "$_yn" =~ ^[sS]$ ]]; then
  echo -n "  Ruta al certificado CA [Enter = /opt/registry/certs/ca.crt]: "
  read -r CERT_PATH
  [ -z "$CERT_PATH" ] && CERT_PATH="/opt/registry/certs/ca.crt"
  [ -f "$CERT_PATH" ] && REGISTRY_CA=$(cat "$CERT_PATH" | sed 's/^/      /') && ok "CA cargado" || warn "Archivo no encontrado, continuando sin CA"
else
  ok "Registry HTTP sin TLS — no requiere CA"
fi

ask_enter

# ──────────────────────────────────────────────────────────────
# PASO 6 — RESUMEN
# ──────────────────────────────────────────────────────────────
banner "PASO 6 de 7 — Resumen de Configuracion"

echo -e "  ${W}${BOLD}CLUSTER${N}"
echo "  Nombre:       ${CLUSTER_NAME}.${BASE_DOMAIN}"
echo "  Topologia:    ${CLUSTER_TYPE} (${NODE_COUNT} nodo/s)"
echo "  OCP:          ${OCP_VERSION}"
echo "  API VIP:      ${API_VIP}"
echo "  Ingress VIP:  ${INGRESS_VIP}"
echo "  Machine CIDR: ${MACHINE_CIDR}"
echo "  Gateway:      ${GATEWAY}"
echo "  DNS:          ${DNS_PRIMARY} / ${DNS_SECONDARY}"
echo "  NTP:          ${NTP_PRIMARY} / ${NTP_SECONDARY}"
echo ""
echo -e "  ${W}${BOLD}NODOS${N}"
for i in "${!NODE_NAMES[@]}"; do
  echo "  ${NODE_NAMES[$i]}  IP: ${NODE_IPS[$i]}  MAC: ${NODE_MACS[$i]}  iface: ${NODE_IFACES[$i]}"
done
echo ""
echo -e "  ${W}${BOLD}REGISTRY${N}"
echo "  Mirror: http://${REGISTRY}"
echo "  ICSP:   ${ICSP_FILE:-generica}"
echo ""

echo -n "  Confirmar y generar la ISO? [s/N]: "
read -r _CONFIRM
if [[ ! "$_CONFIRM" =~ ^[sS]$ ]]; then
  echo "  Cancelado."
  exit 0
fi

# ──────────────────────────────────────────────────────────────
# PASO 7 — GENERACION
# ──────────────────────────────────────────────────────────────
banner "PASO 7 de 7 — Generando archivos e ISO"

CLUSTER_DIR="${OUTPUT_DIR}/${CLUSTER_NAME}"
mkdir -p "${CLUSTER_DIR}"
ok "Directorio: ${CLUSTER_DIR}"

# Pull secret con registry local agregado
PULL_SECRET_RAW=$(cat "$PULL_SECRET_FILE")
LOCAL_AUTH=$(echo -n "unused:unused" | base64 -w0)
PULL_SECRET_MERGED=$(echo "$PULL_SECRET_RAW" | python3 -c "
import sys,json
ps=json.load(sys.stdin)
ps['auths']['${REGISTRY}']={'auth':'${LOCAL_AUTH}','email':'local@local'}
print(json.dumps(ps))")

# ── install-config.yaml ───────────────────────────────────────
step "Generando install-config.yaml..."

[ "$NODE_COUNT" -eq 3 ] && PLATFORM_BLOCK="platform:
  baremetal:
    apiVIPs:
      - ${API_VIP}
    ingressVIPs:
      - ${INGRESS_VIP}" || PLATFORM_BLOCK="platform:
  none: {}"

TRUST_BLOCK=""
[ -n "$REGISTRY_CA" ] && TRUST_BLOCK="additionalTrustBundle: |
${REGISTRY_CA}"

ICS_BLOCK=""
[ -n "$MIRROR_REGISTRIES" ] && ICS_BLOCK="imageContentSources:
${MIRROR_REGISTRIES}"

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
${PLATFORM_BLOCK}
pullSecret: '${PULL_SECRET_MERGED}'
sshKey: '${SSH_KEY}'
${TRUST_BLOCK}
${ICS_BLOCK}
YAML
ok "install-config.yaml generado"

# ── agent-config.yaml ─────────────────────────────────────────
step "Generando agent-config.yaml..."

HOSTS_YAML=""
for i in "${!NODE_NAMES[@]}"; do
  HOSTS_YAML+="  - hostname: ${NODE_NAMES[$i]}
    role: ${NODE_ROLES[$i]}
    interfaces:
      - name: ${NODE_IFACES[$i]}
        macAddress: ${NODE_MACS[$i]}
    networkConfig:
      interfaces:
        - name: ${NODE_IFACES[$i]}
          type: ethernet
          state: up
          ethernet:
            auto-negotiation: true
          ipv4:
            enabled: true
            address:
              - ip: ${NODE_IPS[$i]}
                prefix-length: ${NET_PREFIX}
            dhcp: false
          ipv6:
            enabled: false
      dns-resolver:
        config:
          server:
            - ${DNS_PRIMARY}
            - ${DNS_SECONDARY}
      routes:
        config:
          - destination: 0.0.0.0/0
            next-hop-address: ${GATEWAY}
            next-hop-interface: ${NODE_IFACES[$i]}
            table-id: 254
"
done

cat > "${CLUSTER_DIR}/agent-config.yaml" << YAML
apiVersion: v1alpha1
kind: AgentConfig
metadata:
  name: ${CLUSTER_NAME}
rendezvousIP: ${NODE_IPS[0]}
additionalNTPSources:
  - ${NTP_PRIMARY}
  - ${NTP_SECONDARY}
hosts:
${HOSTS_YAML}
YAML
ok "agent-config.yaml generado"

# ── Generar ISO ───────────────────────────────────────────────
step "Ejecutando openshift-install agent create image..."
echo ""

cd "${CLUSTER_DIR}"
cp install-config.yaml install-config.yaml.bak
cp agent-config.yaml   agent-config.yaml.bak

openshift-install agent create image \
  --dir "${CLUSTER_DIR}" \
  --log-level info \
  2>&1 | tee "${CLUSTER_DIR}/iso-generate.log"

ISO_FILE=$(find "${CLUSTER_DIR}" -name "*.iso" 2>/dev/null | head -1)

echo ""
if [ -n "$ISO_FILE" ] && [ -f "$ISO_FILE" ]; then
  ISO_SIZE=$(du -sh "$ISO_FILE" | cut -f1)

  echo -e "${G}${BOLD}"
  echo "  ╔══════════════════════════════════════════════════════════╗"
  echo "  ║              ISO GENERADA CON EXITO                     ║"
  echo "  ╚══════════════════════════════════════════════════════════╝"
  echo -e "${N}"
  ok "ISO:    ${ISO_FILE}"
  ok "Tamano: ${ISO_SIZE}"
  echo ""
  echo -e "  ${B}${BOLD}╔══════════════════════════════════════════════════════════╗${N}"
  echo -e "  ${B}${BOLD}║                  PROXIMOS PASOS                         ║${N}"
  echo -e "  ${B}${BOLD}╚══════════════════════════════════════════════════════════╝${N}"
  echo ""

  if [ "$NODE_COUNT" -eq 1 ]; then
    echo "  1. Montar la ISO en la VM y bootear"
    echo "     ${NODE_NAMES[0]}  IP: ${NODE_IPS[0]}  MAC: ${NODE_MACS[0]}"
  else
    echo "  1. Montar la MISMA ISO en las 3 VMs y bootear"
    echo "     (pueden arrancar en cualquier orden)"
    for i in "${!NODE_NAMES[@]}"; do
      echo "     ${NODE_NAMES[$i]}  IP: ${NODE_IPS[$i]}  MAC: ${NODE_MACS[$i]}"
    done
  fi
  echo "     ISO: ${ISO_FILE}"

  echo ""
  echo "  2. Monitorear el proceso de instalacion"
  echo ""
  echo "     openshift-install agent wait-for bootstrap-complete \\"
  echo "       --dir ${CLUSTER_DIR}"
  echo ""
  echo "     openshift-install agent wait-for install-complete \\"
  echo "       --dir ${CLUSTER_DIR}"

  echo ""
  echo "  3. Acceder al cluster"
  echo ""
  echo "     export KUBECONFIG=${CLUSTER_DIR}/auth/kubeconfig"
  echo "     oc get nodes"
  echo "     oc get co    # cluster operators"

  echo ""
  echo "  4. Password de kubeadmin"
  echo ""
  echo "     cat ${CLUSTER_DIR}/auth/kubeadmin-password"

  echo ""
  echo "  5. Consola web"
  echo ""
  echo "     https://console-openshift-console.apps.${CLUSTER_NAME}.${BASE_DOMAIN}"

  # Guardar comandos en archivo
  cat > "${CLUSTER_DIR}/post-install-commands.sh" << POSTCMD
#!/bin/bash
# Comandos post-instalacion — ${CLUSTER_NAME}.${BASE_DOMAIN}

# 1. Montar la ISO en la/s VM/s y bootear
#    ISO: ${ISO_FILE}

# 2. Monitorear instalacion
openshift-install agent wait-for bootstrap-complete \\
  --dir ${CLUSTER_DIR}

openshift-install agent wait-for install-complete \\
  --dir ${CLUSTER_DIR}

# 3. Acceder al cluster
export KUBECONFIG=${CLUSTER_DIR}/auth/kubeconfig
oc get nodes
oc get co

# 4. Password de kubeadmin
cat ${CLUSTER_DIR}/auth/kubeadmin-password

# 5. Consola web
echo "https://console-openshift-console.apps.${CLUSTER_NAME}.${BASE_DOMAIN}"
POSTCMD
  chmod +x "${CLUSTER_DIR}/post-install-commands.sh"
  echo ""
  ok "Comandos guardados en: ${CLUSTER_DIR}/post-install-commands.sh"

else
  err "No se encontro la ISO generada."
  warn "Revisar log: ${CLUSTER_DIR}/iso-generate.log"
  echo ""
  echo "  Intento manual:"
  echo "    cd ${CLUSTER_DIR}"
  echo "    cp install-config.yaml.bak install-config.yaml"
  echo "    cp agent-config.yaml.bak   agent-config.yaml"
  echo "    openshift-install agent create image --dir . --log-level debug"
fi

echo ""
echo "  Directorio: ${CLUSTER_DIR}"
echo "  Log:        ${CLUSTER_DIR}/iso-generate.log"
echo ""
