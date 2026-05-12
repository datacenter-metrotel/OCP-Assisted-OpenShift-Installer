#!/bin/bash
# =============================================================
# 05-generate-cluster-iso.sh
# Wizard interactivo para generar ISO(s) de instalacion OCP
# con Agent Based Installer usando el registry local mirror.
# Soporta: 1 nodo (SNO) o 3 nodos (HA)
# Uso: bash /root/OC-Mirror/05-generate-cluster-iso.sh
# =============================================================
set -euo pipefail

RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[1;33m'
BLU='\033[0;34m'; CYN='\033[0;36m'; WHT='\033[1;37m'; NC='\033[0m'
BOLD='\033[1m'; DIM='\033[2m'

WORK_DIR="/root/OC-Mirror"
REGISTRY="172.18.194.190:5000"
PULL_SECRET_FILE="/root/pull-secret.json"
OCP_VERSION="4.15.0"
OUTPUT_DIR="${WORK_DIR}/cluster-output"

# ── Helpers de UI ─────────────────────────────────────────────

banner() {
  echo ""
  printf "${BLU}${BOLD}╔══════════════════════════════════════════════════════════╗\n${NC}"
  printf "${BLU}${BOLD}║${NC}  ${WHT}${BOLD}%-56s${NC}${BLU}${BOLD}║\n${NC}" "$1"
  printf "${BLU}${BOLD}╚══════════════════════════════════════════════════════════╝\n${NC}"
  echo ""
}

step()  { echo ""; echo -e "${CYN}${BOLD}▶ $1${NC}"; echo ""; }
ok()    { echo -e "  ${GRN}✓${NC} $1"; }
warn()  { echo -e "  ${YEL}⚠  $1${NC}"; }
err()   { echo -e "  ${RED}✗  $1${NC}"; }
info()  { echo -e "  ${WHT}→${NC} $1"; }
hint()  { echo -e "  ${DIM}    Ej: $1${NC}"; }
sep()   { echo -e "  ${DIM}──────────────────────────────────────${NC}"; }

# Pregunta con ejemplo y prompt en linea separada
# ask_field "Titulo" "Descripcion ejemplo" "Nombre campo" "default"
ask_field() {
  local title="$1"
  local example="$2"
  local field="$3"
  local default="${4:-}"

  echo ""
  echo -e "  ${WHT}${BOLD}${title}${NC}"
  if [ -n "$example" ]; then
    echo -e "  ${DIM}    Ej: ${example}${NC}"
  fi
  if [ -n "$default" ]; then
    printf "  ${CYN}${field}${NC} ${DIM}[Enter = %s]${NC}: " "$default"
  else
    printf "  ${CYN}${field}${NC}: "
  fi
  read -r _val
  if [ -z "$_val" ] && [ -n "$default" ]; then
    _val="$default"
  fi
  echo "$_val"
}

confirm() {
  local msg="$1"
  echo ""
  printf "  ${WHT}${msg}${NC} ${YEL}[s/N]${NC}: "
  read -r _yn
  [[ "$_yn" =~ ^[sS]$ ]]
}

validate_ip() {
  local ip="$1"
  if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    IFS='.' read -ra _p <<< "$ip"
    for p in "${_p[@]}"; do [ "$p" -le 255 ] 2>/dev/null || return 1; done
    return 0
  fi
  return 1
}

validate_mac() {
  [[ "${1^^}" =~ ^([0-9A-F]{2}:){5}[0-9A-F]{2}$ ]]
}

validate_cidr() {
  local ip="${1%/*}" mask="${1#*/}"
  validate_ip "$ip" && [[ "$mask" =~ ^[0-9]+$ ]] && [ "$mask" -ge 0 ] && [ "$mask" -le 32 ]
}

ask_ip() {
  local title="$1" example="$2" field="$3" default="${4:-}"
  local val
  while true; do
    val=$(ask_field "$title" "$example" "$field" "$default")
    validate_ip "$val" && { echo "$val"; return; }
    err "IP invalida: '$val'   Formato: x.x.x.x  (ej: 172.18.194.10)"
  done
}

ask_mac() {
  local title="$1" field="$2"
  local val
  while true; do
    val=$(ask_field "$title" "AA:BB:CC:DD:EE:FF" "$field" "")
    val="${val^^}"
    validate_mac "$val" && { echo "$val"; return; }
    err "MAC invalida: '$val'   Formato: AA:BB:CC:DD:EE:FF"
  done
}

ask_cidr() {
  local title="$1" example="$2" field="$3" default="${4:-}"
  local val
  while true; do
    val=$(ask_field "$title" "$example" "$field" "$default")
    validate_cidr "$val" && { echo "$val"; return; }
    err "CIDR invalido: '$val'   Formato: x.x.x.x/nn  (ej: 172.18.194.0/24)"
  done
}

# ──────────────────────────────────────────────────────────────
# INICIO
# ──────────────────────────────────────────────────────────────
clear
echo ""
echo -e "${RED}${BOLD}"
echo "   ██████╗  ██████╗██████╗     ██╗    ██╗██╗███████╗ █████╗ ██████╗ ██████╗ "
echo "   ██╔═══██╗██╔════╝██╔══██╗   ██║    ██║██║╚══███╔╝██╔══██╗██╔══██╗██╔══██╗"
echo "   ██║   ██║██║     ██████╔╝   ██║ █╗ ██║██║  ███╔╝ ███████║██████╔╝██║  ██║"
echo "   ██║   ██║██║     ██╔═══╝    ██║███╗██║██║ ███╔╝  ██╔══██║██╔══██╗██║  ██║"
echo "   ╚██████╔╝╚██████╗██║        ╚███╔███╔╝██║███████╗██║  ██║██║  ██║██████╔╝"
echo "    ╚═════╝  ╚═════╝╚═╝         ╚══╝╚══╝ ╚═╝╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝╚═════╝"
echo -e "${NC}"
echo -e "  ${WHT}${BOLD}Generador de ISO — Agent Based Installer — OCP ${OCP_VERSION}${NC}"
echo -e "  ${CYN}Registry local: http://${REGISTRY}${NC}"
echo ""
echo -e "  ${DIM}Este wizard genera install-config.yaml, agent-config.yaml${NC}"
echo -e "  ${DIM}y la ISO de instalacion para clusters de 1 nodo (SNO) o 3 nodos (HA).${NC}"
echo -e "  ${DIM}En cada pregunta se muestra un EJEMPLO. Presiona Enter para aceptar el valor sugerido.${NC}"
echo ""

# ──────────────────────────────────────────────────────────────
# PASO 1: PREREQUISITOS
# ──────────────────────────────────────────────────────────────
banner "PASO 1 de 7 — Verificando prerequisitos"

PREREQ_OK=true

step "Verificando herramientas y servicios..."

if command -v openshift-install &>/dev/null; then
  ok "openshift-install: $(openshift-install version 2>/dev/null | head -1)"
else
  err "openshift-install no encontrado en PATH"
  info "Instalarlo: tar xzf openshift-install-linux.tar.gz && mv openshift-install /usr/local/bin/"
  PREREQ_OK=false
fi

if command -v oc &>/dev/null; then
  ok "oc CLI: $(oc version --client 2>/dev/null | head -1)"
else
  warn "oc no encontrado — no es critico para generar la ISO"
fi

if [ -f "$PULL_SECRET_FILE" ]; then
  ok "Pull secret: $PULL_SECRET_FILE"
else
  err "No se encontro $PULL_SECRET_FILE"
  info "Descargarlo en: https://console.redhat.com/openshift/install/pull-secret"
  PREREQ_OK=false
fi

if curl -s --max-time 5 "http://${REGISTRY}/v2/" | grep -q "{}"; then
  REPO_COUNT=$(curl -s "http://${REGISTRY}/v2/_catalog" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('repositories',[])))" 2>/dev/null || echo "?")
  ok "Registry local: http://${REGISTRY} — ${REPO_COUNT} repositorios"
else
  err "Registry local no responde en http://${REGISTRY}/v2/"
  warn "Verificar: podman ps | grep local-registry"
  PREREQ_OK=false
fi

ICSP_FILE=$(find "${WORK_DIR}/oc-mirror-workspace" -name "imageContentSourcePolicy*.yaml" 2>/dev/null | sort | tail -1)
[ -z "$ICSP_FILE" ] && ICSP_FILE=$(find "${WORK_DIR}" -name "mirror-config-para-UI.yaml" 2>/dev/null | head -1)
if [ -n "$ICSP_FILE" ]; then
  ok "ICSP encontrado: $ICSP_FILE"
else
  warn "No se encontro ICSP. Ejecutar primero: bash ${WORK_DIR}/02-run-mirror.sh"
fi

if [ "$PREREQ_OK" = false ]; then
  echo ""
  err "Hay prerequisitos faltantes. Resolver antes de continuar."
  exit 1
fi

echo ""
ok "Todos los prerequisitos OK"
echo ""
printf "  Presiona ENTER para continuar..."; read -r _

# ──────────────────────────────────────────────────────────────
# PASO 2: TOPOLOGIA
# ──────────────────────────────────────────────────────────────
banner "PASO 2 de 7 — Topologia del Cluster"

echo -e "  ${WHT}${BOLD}Selecciona el tipo de cluster:${NC}"
echo ""
echo -e "  ${YEL}1)${NC} ${BOLD}SNO — Single Node OpenShift${NC}"
echo -e "       1 VM que cumple los roles de etcd + control plane + worker"
echo -e "       ${DIM}Ideal para labs, desarrollo o recursos limitados${NC}"
echo ""
echo -e "  ${YEL}3)${NC} ${BOLD}HA — High Availability${NC}"
echo -e "       3 VMs, cada una es control plane + etcd"
echo -e "       ${DIM}Produccion. Cada nodo tambien puede schedulear workloads${NC}"
echo ""

while true; do
  printf "  ${WHT}Cantidad de nodos${NC} ${DIM}[1 = SNO / 3 = HA]${NC}: "
  read -r NODE_COUNT
  case "$NODE_COUNT" in
    1) CLUSTER_TYPE="SNO"; break ;;
    3) CLUSTER_TYPE="HA";  break ;;
    *) err "Ingresar 1 o 3" ;;
  esac
done

echo ""
ok "Topologia: ${BOLD}${CLUSTER_TYPE}${NC} — ${NODE_COUNT} nodo(s)"
if [ "$NODE_COUNT" -eq 1 ]; then
  info "Una sola ISO. La VM se configura sola al bootear."
else
  info "Una sola ISO para las 3 VMs. Cada VM se identifica por su MAC address."
fi
echo ""
printf "  Presiona ENTER para continuar..."; read -r _

# ──────────────────────────────────────────────────────────────
# PASO 3: DATOS DEL CLUSTER
# ──────────────────────────────────────────────────────────────
banner "PASO 3 de 7 — Datos del Cluster"

# ── Nombre y dominio ──────────────────────────────────────────
step "Identificacion del cluster"
echo -e "  ${DIM}El nombre del cluster y el dominio base forman el FQDN del cluster.${NC}"
echo -e "  ${DIM}Ejemplo: cluster 'ocp-upstream' + dominio 'metrotel.xdc'${NC}"
echo -e "  ${DIM}  -> API:    api.ocp-upstream.metrotel.xdc${NC}"
echo -e "  ${DIM}  -> Apps:   *.apps.ocp-upstream.metrotel.xdc${NC}"
sep

CLUSTER_NAME=$(ask_field \
  "Nombre del cluster" \
  "ocp-upstream" \
  "Nombre" \
  "ocp-upstream")

BASE_DOMAIN=$(ask_field \
  "Dominio base de la organizacion" \
  "metrotel.xdc" \
  "Dominio" \
  "metrotel.xdc")

echo ""
ok "FQDN del cluster: ${BOLD}${CLUSTER_NAME}.${BASE_DOMAIN}${NC}"
info "API:   api.${CLUSTER_NAME}.${BASE_DOMAIN}"
info "Apps:  *.apps.${CLUSTER_NAME}.${BASE_DOMAIN}"

# ── CIDRs ─────────────────────────────────────────────────────
step "Redes del cluster"
echo -e "  ${DIM}Machine CIDR: red donde viven las VMs (tu red de infraestructura).${NC}"
echo -e "  ${DIM}Cluster Net:  red interna de pods (no debe superponerse con la red de VMs).${NC}"
echo -e "  ${DIM}Service Net:  red interna de servicios Kubernetes.${NC}"
sep

MACHINE_CIDR=$(ask_cidr \
  "Red de las VMs (machine network)" \
  "172.18.194.0/24" \
  "Machine CIDR" \
  "172.18.194.0/24")

CLUSTER_NET=$(ask_cidr \
  "Red interna de pods" \
  "10.128.0.0/14" \
  "Cluster Network" \
  "10.128.0.0/14")

SERVICE_NET=$(ask_cidr \
  "Red interna de servicios Kubernetes" \
  "172.30.0.0/16" \
  "Service Network" \
  "172.30.0.0/16")

# ── VIPs ──────────────────────────────────────────────────────
if [ "$NODE_COUNT" -eq 3 ]; then
  step "VIPs — IPs Virtuales del cluster"
  echo -e "  ${DIM}Los VIPs son IPs flotantes que NO deben estar asignadas a ninguna VM.${NC}"
  echo -e "  ${DIM}Deben estar libres dentro del rango de ${MACHINE_CIDR}.${NC}"
  echo -e "  ${DIM}El API VIP recibe las conexiones a la API de Kubernetes.${NC}"
  echo -e "  ${DIM}El Ingress VIP recibe el trafico de las aplicaciones (*.apps.*).${NC}"
  sep

  API_VIP=$(ask_ip \
    "VIP para la API del cluster" \
    "172.18.194.100  (debe estar libre, no usada por ninguna VM)" \
    "API VIP" \
    "172.18.194.100")

  INGRESS_VIP=$(ask_ip \
    "VIP para el Ingress / Apps" \
    "172.18.194.101  (debe estar libre, diferente al API VIP)" \
    "Ingress VIP" \
    "172.18.194.101")

  ok "API VIP:    ${API_VIP}"
  ok "Ingress VIP: ${INGRESS_VIP}"
fi

# ── DNS ───────────────────────────────────────────────────────
step "Servidores DNS"
echo -e "  ${DIM}Las VMs usaran estos DNS durante y despues de la instalacion.${NC}"
echo -e "  ${DIM}El DNS primario debe poder resolver los nombres del cluster${NC}"
echo -e "  ${DIM}(api.* y *.apps.*) que configuraremos mas adelante.${NC}"
sep

DNS_PRIMARY=$(ask_ip \
  "Servidor DNS primario" \
  "172.18.194.36" \
  "DNS primario" \
  "172.18.194.36")

DNS_SECONDARY=$(ask_ip \
  "Servidor DNS secundario (opcional, Enter para omitir)" \
  "172.18.194.37" \
  "DNS secundario" \
  "172.18.194.37")
DNS_SERVER="$DNS_PRIMARY"

# ── NTP ───────────────────────────────────────────────────────
step "Servidores NTP"
echo -e "  ${DIM}Los nodos del cluster necesitan sincronizacion de tiempo.${NC}"
echo -e "  ${DIM}Usar el mismo NTP que el resto de la infraestructura.${NC}"
sep

NTP_PRIMARY=$(ask_field \
  "Servidor NTP primario" \
  "172.18.194.36" \
  "NTP primario" \
  "172.18.194.36")

NTP_SECONDARY=$(ask_field \
  "Servidor NTP secundario (opcional)" \
  "172.18.194.37" \
  "NTP secundario" \
  "172.18.194.37")

# ── SSH Key ───────────────────────────────────────────────────
step "Clave SSH para acceso a los nodos"
echo -e "  ${DIM}Esta clave SSH publica se inyecta en todos los nodos del cluster.${NC}"
echo -e "  ${DIM}Permite hacer 'ssh core@IP_DEL_NODO' para debug si es necesario.${NC}"
sep

if [ -f ~/.ssh/id_rsa.pub ]; then
  info "Clave encontrada en ~/.ssh/id_rsa.pub"
  echo -e "  ${DIM}$(cat ~/.ssh/id_rsa.pub | cut -c1-60)...${NC}"
  echo ""
  if confirm "Usar esta clave SSH?"; then
    SSH_KEY=$(cat ~/.ssh/id_rsa.pub)
    ok "Usando clave de ~/.ssh/id_rsa.pub"
  else
    echo ""
    printf "  ${CYN}Clave SSH publica${NC}: "
    read -r SSH_KEY
  fi
else
  warn "No se encontro ~/.ssh/id_rsa.pub"
  info "Para generar una: ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N ''"
  echo ""
  printf "  ${CYN}Clave SSH publica${NC} ${DIM}(pegar aqui o Enter para omitir)${NC}: "
  read -r SSH_KEY
fi

echo ""
printf "  Presiona ENTER para continuar..."; read -r _

# ──────────────────────────────────────────────────────────────
# PASO 4: NODOS
# ──────────────────────────────────────────────────────────────
banner "PASO 4 de 7 — Configuracion de los Nodos"

echo -e "  ${DIM}Por cada VM necesitamos su MAC address, IP fija y la interfaz de red.${NC}"
echo -e "  ${DIM}La MAC address identifica cada VM de forma unica para asignarle hostname,${NC}"
echo -e "  ${DIM}IP y rol durante la instalacion.${NC}"

declare -a NODE_NAMES=()
declare -a NODE_MACS=()
declare -a NODE_IPS=()
declare -a NODE_IFACES=()
declare -a NODE_ROLES=()

collect_node() {
  local idx=$1
  local name
  [ "$NODE_COUNT" -eq 1 ] && name="master-0" || name="master-${idx}"

  echo ""
  echo -e "  ${YEL}${BOLD}── Nodo $((idx+1)) de ${NODE_COUNT}: ${name} ──${NC}"
  echo ""

  # MAC
  local mac
  echo -e "  ${WHT}${BOLD}MAC address de la VM${NC}"
  echo -e "  ${DIM}    Ej: 52:54:00:AB:CD:$((10+idx*11)):$((idx+1))  (obtenla en el hipervisor)${NC}"
  while true; do
    printf "  ${CYN}MAC${NC}: "
    read -r mac
    mac="${mac^^}"
    validate_mac "$mac" && break
    err "MAC invalida. Formato requerido: AA:BB:CC:DD:EE:FF"
  done

  # IP
  local default_ip
  IFS='.' read -ra _net <<< "${MACHINE_CIDR%/*}"
  default_ip="${_net[0]}.${_net[1]}.${_net[2]}.$((10+idx))"
  local ip
  echo ""
  echo -e "  ${WHT}${BOLD}IP estatica del nodo${NC}"
  echo -e "  ${DIM}    Ej: ${default_ip}  (debe estar libre y dentro de ${MACHINE_CIDR})${NC}"
  while true; do
    printf "  ${CYN}IP${NC} ${DIM}[Enter = ${default_ip}]${NC}: "
    read -r ip
    [ -z "$ip" ] && ip="$default_ip"
    validate_ip "$ip" && break
    err "IP invalida. Formato: x.x.x.x"
  done

  # Interfaz
  local iface
  echo ""
  echo -e "  ${WHT}${BOLD}Nombre de la interfaz de red en la VM${NC}"
  echo -e "  ${DIM}    Ej: ens3  (KVM/QEMU)  |  eth0  (generico)  |  ens192 (VMware)${NC}"
  printf "  ${CYN}Interfaz${NC} ${DIM}[Enter = ens3]${NC}: "
  read -r iface
  [ -z "$iface" ] && iface="ens3"

  NODE_NAMES+=("$name")
  NODE_MACS+=("$mac")
  NODE_IPS+=("$ip")
  NODE_IFACES+=("$iface")
  NODE_ROLES+=("master")

  echo ""
  ok "Nodo ${name} configurado"
  info "MAC:      ${mac}"
  info "IP:       ${ip}"
  info "Interfaz: ${iface}"
  info "Rol:      master (etcd + control-plane + worker)"
}

if [ "$NODE_COUNT" -eq 1 ]; then
  collect_node 0
  API_VIP="${NODE_IPS[0]}"
  INGRESS_VIP="${NODE_IPS[0]}"
  info "SNO: API VIP e Ingress VIP = ${API_VIP}"
else
  for i in 0 1 2; do collect_node "$i"; done
fi

# ── Prefijo de red ────────────────────────────────────────────
echo ""
step "Prefijo de red (mascara)"
echo -e "  ${DIM}Para la red ${MACHINE_CIDR} el prefijo es ${MACHINE_CIDR#*/}.${NC}"
echo -e "  ${DIM}    Ej: /24 = mascara 255.255.255.0${NC}"
printf "  ${CYN}Prefijo${NC} ${DIM}[Enter = ${MACHINE_CIDR#*/}]${NC}: "
read -r NET_PREFIX
[ -z "$NET_PREFIX" ] && NET_PREFIX="${MACHINE_CIDR#*/}"

# Calcular gateway sugerido
IFS='.' read -ra _gw <<< "${MACHINE_CIDR%/*}"
GW_SUGGESTED="${_gw[0]}.${_gw[1]}.${_gw[2]}.1"

echo ""
step "Gateway de la red"
echo -e "  ${DIM}Router/gateway por defecto de la red ${MACHINE_CIDR}.${NC}"
echo -e "  ${DIM}    Ej: ${GW_SUGGESTED}${NC}"
while true; do
  printf "  ${CYN}Gateway${NC} ${DIM}[Enter = ${GW_SUGGESTED}]${NC}: "
  read -r GATEWAY
  [ -z "$GATEWAY" ] && GATEWAY="$GW_SUGGESTED"
  validate_ip "$GATEWAY" && break
  err "IP invalida. Formato: x.x.x.x"
done

# ── Mostrar DNS a crear ───────────────────────────────────────
echo ""
echo -e "  ${YEL}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "  ${YEL}${BOLD}║      REGISTROS DNS QUE DEBES CREAR ANTES DE BOOTEAR     ║${NC}"
echo -e "  ${YEL}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Servidor DNS: ${WHT}${DNS_PRIMARY}${NC}"
echo ""

if [ "$NODE_COUNT" -eq 1 ]; then
  echo -e "  ${GRN}# API y Ingress (SNO: misma IP para todo)${NC}"
  echo -e "  ${BOLD}api.${CLUSTER_NAME}.${BASE_DOMAIN}.          IN A  ${API_VIP}${NC}"
  echo -e "  ${BOLD}api-int.${CLUSTER_NAME}.${BASE_DOMAIN}.      IN A  ${API_VIP}${NC}"
  echo -e "  ${BOLD}*.apps.${CLUSTER_NAME}.${BASE_DOMAIN}.       IN A  ${INGRESS_VIP}${NC}"
  echo -e "  ${BOLD}master-0.${CLUSTER_NAME}.${BASE_DOMAIN}.     IN A  ${NODE_IPS[0]}${NC}"
  echo ""
  echo -e "  ${GRN}# DNS inverso (PTR)${NC}"
  IFS='.' read -ra _o <<< "${API_VIP}"
  echo -e "  ${BOLD}${_o[3]}.${_o[2]}.${_o[1]}.${_o[0]}.in-addr.arpa.  IN PTR  api.${CLUSTER_NAME}.${BASE_DOMAIN}.${NC}"
  echo ""
  echo -e "  ${GRN}# /etc/hosts alternativo en este servidor:${NC}"
  echo -e "  ${CYN}echo '${API_VIP}  api.${CLUSTER_NAME}.${BASE_DOMAIN} api-int.${CLUSTER_NAME}.${BASE_DOMAIN}' >> /etc/hosts${NC}"
  echo -e "  ${CYN}echo '${API_VIP}  console-openshift-console.apps.${CLUSTER_NAME}.${BASE_DOMAIN}' >> /etc/hosts${NC}"
  echo -e "  ${CYN}echo '${API_VIP}  oauth-openshift.apps.${CLUSTER_NAME}.${BASE_DOMAIN}' >> /etc/hosts${NC}"
else
  echo -e "  ${GRN}# API e Ingress${NC}"
  echo -e "  ${BOLD}api.${CLUSTER_NAME}.${BASE_DOMAIN}.          IN A  ${API_VIP}${NC}"
  echo -e "  ${BOLD}api-int.${CLUSTER_NAME}.${BASE_DOMAIN}.      IN A  ${API_VIP}${NC}"
  echo -e "  ${BOLD}*.apps.${CLUSTER_NAME}.${BASE_DOMAIN}.       IN A  ${INGRESS_VIP}${NC}"
  echo ""
  echo -e "  ${GRN}# Un registro A por nodo${NC}"
  for i in "${!NODE_NAMES[@]}"; do
    echo -e "  ${BOLD}${NODE_NAMES[$i]}.${CLUSTER_NAME}.${BASE_DOMAIN}.  IN A  ${NODE_IPS[$i]}${NC}"
  done
  echo ""
  echo -e "  ${GRN}# DNS inverso (PTR)${NC}"
  IFS='.' read -ra _o <<< "${API_VIP}"; echo -e "  ${BOLD}${_o[3]}.${_o[2]}.${_o[1]}.${_o[0]}.in-addr.arpa.  IN PTR  api.${CLUSTER_NAME}.${BASE_DOMAIN}.${NC}"
  for i in "${!NODE_NAMES[@]}"; do
    IFS='.' read -ra _o <<< "${NODE_IPS[$i]}"
    echo -e "  ${BOLD}${_o[3]}.${_o[2]}.${_o[1]}.${_o[0]}.in-addr.arpa.  IN PTR  ${NODE_NAMES[$i]}.${CLUSTER_NAME}.${BASE_DOMAIN}.${NC}"
  done
  echo ""
  echo -e "  ${GRN}# SRV records para etcd (requeridos en HA)${NC}"
  for i in "${!NODE_NAMES[@]}"; do
    echo -e "  ${BOLD}_etcd-server-ssl._tcp.${CLUSTER_NAME}.${BASE_DOMAIN}.  IN SRV  0 10 2380 ${NODE_NAMES[$i]}.${CLUSTER_NAME}.${BASE_DOMAIN}.${NC}"
  done
  echo ""
  echo -e "  ${GRN}# /etc/hosts alternativo en este servidor:${NC}"
  echo -e "  ${CYN}echo '${API_VIP}     api.${CLUSTER_NAME}.${BASE_DOMAIN} api-int.${CLUSTER_NAME}.${BASE_DOMAIN}' >> /etc/hosts${NC}"
  echo -e "  ${CYN}echo '${INGRESS_VIP} console-openshift-console.apps.${CLUSTER_NAME}.${BASE_DOMAIN}' >> /etc/hosts${NC}"
  echo -e "  ${CYN}echo '${INGRESS_VIP} oauth-openshift.apps.${CLUSTER_NAME}.${BASE_DOMAIN}' >> /etc/hosts${NC}"
fi
echo ""
echo -e "  ${RED}${BOLD}IMPORTANTE:${NC} Crear estos registros ANTES de bootear las VMs con la ISO."
echo ""
printf "  Presiona ENTER cuando hayas anotado o creado los registros DNS..."; read -r _

# ──────────────────────────────────────────────────────────────
# PASO 5: MIRROR
# ──────────────────────────────────────────────────────────────
banner "PASO 5 de 7 — Configuracion del Registry Mirror"

step "Registry local"
info "Registry: http://${REGISTRY}"
info "Las imagenes de OCP se sirven desde el registry local."
info "El cluster NO necesitara acceso a internet."
echo ""

MIRROR_REGISTRIES=""
if [ -n "$ICSP_FILE" ] && [ -f "$ICSP_FILE" ]; then
  ok "ICSP: $ICSP_FILE"
  MIRROR_REGISTRIES=$(python3 << PYEOF
import yaml
try:
    with open("${ICSP_FILE}") as f:
        doc = yaml.safe_load(f)
    entries = doc.get("spec", {}).get("repositoryDigestMirrors", [])
    lines = []
    for e in entries:
        src = e.get("source",""); mirrors = e.get("mirrors",[])
        if src and mirrors:
            lines.append(f"  - source: {src}\n    mirrors:")
            for m in mirrors: lines.append(f"    - {m}")
    print('\n'.join(lines))
except Exception as ex:
    print(f"  # Error: {ex}")
PYEOF
)
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
if confirm "El registry usa TLS con certificado propio? (no = HTTP plain, responder N)"; then
  printf "  ${CYN}Ruta al certificado CA${NC} ${DIM}[Enter = /opt/registry/certs/ca.crt]${NC}: "
  read -r CERT_PATH
  [ -z "$CERT_PATH" ] && CERT_PATH="/opt/registry/certs/ca.crt"
  if [ -f "$CERT_PATH" ]; then
    REGISTRY_CA=$(cat "$CERT_PATH" | sed 's/^/      /')
    ok "Certificado CA cargado"
  else
    err "Archivo no encontrado: $CERT_PATH — continuando sin CA"
  fi
else
  ok "Registry HTTP sin TLS — no requiere CA"
fi

echo ""
printf "  Presiona ENTER para continuar..."; read -r _

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
echo -e "  Gateway:       ${GRN}${GATEWAY}${NC}"
echo -e "  DNS:           ${GRN}${DNS_PRIMARY}${NC} / ${GRN}${DNS_SECONDARY}${NC}"
echo -e "  NTP:           ${GRN}${NTP_PRIMARY}${NC} / ${GRN}${NTP_SECONDARY}${NC}"
echo ""
echo -e "  ${WHT}${BOLD}NODOS${NC}"
for i in "${!NODE_NAMES[@]}"; do
  echo -e "  ${YEL}${NODE_NAMES[$i]}${NC}  IP: ${GRN}${NODE_IPS[$i]}${NC}  MAC: ${GRN}${NODE_MACS[$i]}${NC}  iface: ${GRN}${NODE_IFACES[$i]}${NC}"
done
echo ""
echo -e "  ${WHT}${BOLD}REGISTRY${NC}"
echo -e "  Mirror: ${GRN}http://${REGISTRY}${NC}"
echo -e "  ICSP:   ${GRN}${ICSP_FILE:-generica}${NC}"
echo ""

if ! confirm "Confirmar y generar la ISO?"; then
  warn "Cancelado por el usuario."
  exit 0
fi

# ──────────────────────────────────────────────────────────────
# PASO 7: GENERACION
# ──────────────────────────────────────────────────────────────
banner "PASO 7 de 7 — Generando archivos e ISO"

CLUSTER_DIR="${OUTPUT_DIR}/${CLUSTER_NAME}"
mkdir -p "${CLUSTER_DIR}"
ok "Directorio: ${CLUSTER_DIR}"

# ── Pull secret con registry local ───────────────────────────
PULL_SECRET_RAW=$(cat "$PULL_SECRET_FILE")
LOCAL_AUTH=$(echo -n "unused:unused" | base64 -w0)
PULL_SECRET_MERGED=$(echo "$PULL_SECRET_RAW" | python3 -c "
import sys,json
ps=json.load(sys.stdin)
ps['auths']['${REGISTRY}']={'auth':'${LOCAL_AUTH}','email':'local@local'}
print(json.dumps(ps))")

# ── install-config.yaml ───────────────────────────────────────
step "Generando install-config.yaml..."

if [ "$NODE_COUNT" -eq 3 ]; then
  PLATFORM_SECTION="platform:
  baremetal:
    apiVIPs:
      - ${API_VIP}
    ingressVIPs:
      - ${INGRESS_VIP}"
else
  PLATFORM_SECTION="platform:
  none: {}"
fi

TRUST_BUNDLE=""
[ -n "$REGISTRY_CA" ] && TRUST_BUNDLE="additionalTrustBundle: |
${REGISTRY_CA}"

ICS_SECTION=""
[ -n "$MIRROR_REGISTRIES" ] && ICS_SECTION="imageContentSources:
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
${PLATFORM_SECTION}
pullSecret: '${PULL_SECRET_MERGED}'
sshKey: '${SSH_KEY}'
${TRUST_BUNDLE}
${ICS_SECTION}
YAML
ok "install-config.yaml generado"

# ── agent-config.yaml ─────────────────────────────────────────
step "Generando agent-config.yaml..."

NTP_SECTION="  - ${NTP_PRIMARY}"
[ -n "$NTP_SECONDARY" ] && NTP_SECTION="${NTP_SECTION}
  - ${NTP_SECONDARY}"

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
          macAddress: ${NODE_MACS[$i]}
          ipv4:
            enabled: true
            address:
              - ip: ${NODE_IPS[$i]}
                prefix-length: ${NET_PREFIX}
            dhcp: false
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
${NTP_SECTION}
hosts:
${HOSTS_YAML}
YAML
ok "agent-config.yaml generado"

# ── Backup y generar ISO ──────────────────────────────────────
step "Ejecutando openshift-install agent create image..."
echo ""

cd "${CLUSTER_DIR}"
cp install-config.yaml install-config.yaml.bak
cp agent-config.yaml   agent-config.yaml.bak

openshift-install agent create image \
  --dir "${CLUSTER_DIR}" \
  --log-level info \
  2>&1 | tee "${CLUSTER_DIR}/iso-generate.log"

ISO_FILE=$(find "${CLUSTER_DIR}" -name "agent.x86_64.iso" -o -name "*.iso" 2>/dev/null | grep -v ".bak" | head -1)

echo ""
if [ -n "$ISO_FILE" ] && [ -f "$ISO_FILE" ]; then
  ISO_SIZE=$(du -sh "$ISO_FILE" | cut -f1)

  echo -e "${GRN}${BOLD}"
  echo "  ╔══════════════════════════════════════════════════════════╗"
  echo "  ║              ISO GENERADA CON EXITO                     ║"
  echo "  ╚══════════════════════════════════════════════════════════╝"
  echo -e "${NC}"
  ok "ISO:    ${ISO_FILE}"
  ok "Tamano: ${ISO_SIZE}"

  echo ""
  echo -e "  ${BLU}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
  echo -e "  ${BLU}${BOLD}║                  PROXIMOS PASOS                         ║${NC}"
  echo -e "  ${BLU}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
  echo ""

  if [ "$NODE_COUNT" -eq 1 ]; then
    echo -e "  ${YEL}${BOLD}1. Montar la ISO en la VM y bootear${NC}"
    echo -e "     ${GRN}${NODE_NAMES[0]}${NC}  IP: ${GRN}${NODE_IPS[0]}${NC}  MAC: ${GRN}${NODE_MACS[0]}${NC}"
  else
    echo -e "  ${YEL}${BOLD}1. Montar la MISMA ISO en las 3 VMs y bootear${NC}"
    echo -e "     ${DIM}(pueden arrancar en cualquier orden)${NC}"
    echo ""
    for i in "${!NODE_NAMES[@]}"; do
      echo -e "     ${GRN}${NODE_NAMES[$i]}${NC}  IP: ${GRN}${NODE_IPS[$i]}${NC}  MAC: ${GRN}${NODE_MACS[$i]}${NC}"
    done
  fi
  echo -e "     ISO: ${CYN}${ISO_FILE}${NC}"

  echo ""
  echo -e "  ${YEL}${BOLD}2. Monitorear el proceso de instalacion${NC}"
  echo ""
  echo -e "  ${CYN}openshift-install agent wait-for bootstrap-complete \\${NC}"
  echo -e "  ${CYN}  --dir ${CLUSTER_DIR}${NC}"
  echo ""
  echo -e "  ${CYN}openshift-install agent wait-for install-complete \\${NC}"
  echo -e "  ${CYN}  --dir ${CLUSTER_DIR}${NC}"

  echo ""
  echo -e "  ${YEL}${BOLD}3. Acceder al cluster${NC}"
  echo ""
  echo -e "  ${CYN}export KUBECONFIG=${CLUSTER_DIR}/auth/kubeconfig${NC}"
  echo -e "  ${CYN}oc get nodes${NC}"
  echo -e "  ${CYN}oc get co${NC}  ${DIM}# cluster operators${NC}"

  echo ""
  echo -e "  ${YEL}${BOLD}4. Password de kubeadmin${NC}"
  echo ""
  echo -e "  ${CYN}cat ${CLUSTER_DIR}/auth/kubeadmin-password${NC}"

  echo ""
  echo -e "  ${YEL}${BOLD}5. Consola web${NC}"
  echo ""
  echo -e "  ${WHT}https://console-openshift-console.apps.${CLUSTER_NAME}.${BASE_DOMAIN}${NC}"

  # Guardar comandos en archivo
  cat > "${CLUSTER_DIR}/post-install-commands.sh" << POSTCMD
#!/bin/bash
# ============================================================
# Comandos post-instalacion
# Cluster: ${CLUSTER_NAME}.${BASE_DOMAIN}
# Generado por 05-generate-cluster-iso.sh
# ============================================================

# 1. Montar la ISO en la/s VM/s y bootear
#    ISO: ${ISO_FILE}
EOF_ISO

# 2. Monitorear el proceso de instalacion
openshift-install agent wait-for bootstrap-complete \\
  --dir ${CLUSTER_DIR}

openshift-install agent wait-for install-complete \\
  --dir ${CLUSTER_DIR}

# 3. Acceder al cluster
export KUBECONFIG=${CLUSTER_DIR}/auth/kubeconfig
oc get nodes
oc get co    # cluster operators

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
  echo -e "  ${WHT}Intento manual:${NC}"
  echo -e "  ${CYN}cd ${CLUSTER_DIR}${NC}"
  echo -e "  ${CYN}cp install-config.yaml.bak install-config.yaml${NC}"
  echo -e "  ${CYN}cp agent-config.yaml.bak   agent-config.yaml${NC}"
  echo -e "  ${CYN}openshift-install agent create image --dir . --log-level debug${NC}"
fi

echo ""
echo -e "  ${CYN}Directorio: ${CLUSTER_DIR}${NC}"
echo -e "  ${CYN}Log:        ${CLUSTER_DIR}/iso-generate.log${NC}"
echo ""
