#!/bin/bash
# =============================================================
# 01-setup-mirror.sh
# Prepara el entorno para el mirroring de OCP 4.15
# Ejecutar como: bash /root/OC-Mirror/01-setup-mirror.sh
# =============================================================
set -euo pipefail

WORK_DIR="/root/OC-Mirror"
OCP_VERSION="4.15"

mkdir -p "${WORK_DIR}"
cd "${WORK_DIR}"
echo "    Directorio de trabajo: ${WORK_DIR}"

echo ""
echo "==> [1/4] Verificando espacio en disco (mínimo 100GB en /opt/registry)"
mkdir -p /opt/registry
AVAILABLE_GB=$(df -BG /opt/registry | awk 'NR==2 {print $4}' | tr -d 'G')
if [ "${AVAILABLE_GB}" -lt 100 ]; then
  echo "    ADVERTENCIA: Solo hay ${AVAILABLE_GB}GB disponibles. Se recomiendan al menos 100GB."
  echo "    Continuando de todas formas..."
else
  echo "    OK: ${AVAILABLE_GB}GB disponibles."
fi

echo ""
echo "==> [2/4] Instalando dependencias"
dnf install -y wget curl jq podman skopeo

echo ""
echo "==> [3/4] Descargando oc-mirror para OCP ${OCP_VERSION}"
OC_MIRROR_URL="https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest-${OCP_VERSION}/oc-mirror.tar.gz"
wget -q --show-progress -O /tmp/oc-mirror.tar.gz "${OC_MIRROR_URL}"
tar -xvf /tmp/oc-mirror.tar.gz -C /tmp/
chmod +x /tmp/oc-mirror
mv /tmp/oc-mirror /usr/local/bin/oc-mirror
echo "    oc-mirror instalado en: $(which oc-mirror)"
oc-mirror version 2>/dev/null || true

echo ""
echo "==> [4/4] Descargando oc CLI"
OC_URL="https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest-${OCP_VERSION}/openshift-client-linux.tar.gz"
wget -q --show-progress -O /tmp/oc-client.tar.gz "${OC_URL}"
tar -xvf /tmp/oc-client.tar.gz -C /tmp/
mv /tmp/oc /usr/local/bin/oc
mv /tmp/kubectl /usr/local/bin/kubectl 2>/dev/null || true
echo "    oc CLI instalado: $(oc version --client 2>/dev/null | head -1)"

echo ""
echo "============================================="
echo " Setup completo."
echo " Estructura de trabajo: ${WORK_DIR}"
echo ""
echo " Próximo paso:"
echo "   bash ${WORK_DIR}/02-run-mirror.sh"
echo "============================================="
