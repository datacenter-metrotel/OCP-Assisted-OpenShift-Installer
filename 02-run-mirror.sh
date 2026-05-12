#!/bin/bash
# =============================================================
# 02-run-mirror.sh
# Ejecuta el mirroring completo de OCP 4.15 al registry local
# Ejecutar como: bash /root/OC-Mirror/02-run-mirror.sh
# =============================================================
set -euo pipefail

WORK_DIR="/root/OC-Mirror"
REGISTRY_HOST="172.18.194.190"
REGISTRY_PORT="5000"
REGISTRY_URL="${REGISTRY_HOST}:${REGISTRY_PORT}"
IMAGESET_CONFIG="${WORK_DIR}/imageset-config.yaml"
PULL_SECRET="/root/pull-secret.json"

# Moverse al directorio de trabajo — oc-mirror crea su workspace aquí
mkdir -p "${WORK_DIR}"
cd "${WORK_DIR}"
echo "    Directorio de trabajo: ${WORK_DIR}"

# -------------------------------------------------------
# PASO 0: Validaciones previas
# -------------------------------------------------------
echo ""
echo "==> [0/4] Validaciones previas"

if [ ! -f "${IMAGESET_CONFIG}" ]; then
  echo "ERROR: No se encontró ${IMAGESET_CONFIG}"
  echo "  Copiá el archivo imageset-config.yaml a ${WORK_DIR}/"
  exit 1
fi
echo "    ✓ imageset-config.yaml encontrado"

if [ ! -f "${PULL_SECRET}" ]; then
  echo "ERROR: No se encontró el pull-secret en ${PULL_SECRET}"
  echo "  Descargalo desde https://console.redhat.com/openshift/install/pull-secret"
  exit 1
fi
echo "    ✓ pull-secret.json encontrado"

echo "    Verificando registry local en http://${REGISTRY_URL}..."
if ! curl -s --max-time 5 "http://${REGISTRY_URL}/v2/" > /dev/null; then
  echo "ERROR: El registry local no responde en http://${REGISTRY_URL}/v2/"
  echo "  Verificá que el contenedor 'local-registry' esté corriendo:"
  echo "  podman ps | grep local-registry"
  exit 1
fi
echo "    ✓ Registry OK"

# -------------------------------------------------------
# PASO 1: Configurar credenciales
# -------------------------------------------------------
echo ""
echo "==> [1/4] Configurando credenciales"

# Merge: pull-secret Red Hat + entrada para registry local (sin auth)
LOCAL_AUTH=$(echo -n "unused:unused" | base64 -w0)
jq --arg reg "${REGISTRY_URL}" \
   --arg auth "${LOCAL_AUTH}" \
   '.auths[$reg] = {"auth": $auth, "email": "local@local"}' \
   "${PULL_SECRET}" > /tmp/merged-pull-secret.json

echo "    ✓ Pull secret cargado desde ${PULL_SECRET}"
echo "    ✓ Entrada agregada para ${REGISTRY_URL}"

# Verificar credenciales Red Hat
echo "    Verificando credenciales contra registry.redhat.io..."
if skopeo inspect \
     --authfile /tmp/merged-pull-secret.json \
     --tls-verify=true \
     docker://registry.redhat.io/ubi8/ubi:latest \
     > /dev/null 2>&1; then
  echo "    ✓ Credenciales Red Hat válidas"
else
  echo "    ✗ ERROR: No se pudo autenticar contra registry.redhat.io"
  echo "      Renovar pull-secret en: https://console.redhat.com/openshift/install/pull-secret"
  exit 1
fi

# oc-mirror lee desde ~/.docker/config.json
mkdir -p ~/.docker
cp /tmp/merged-pull-secret.json ~/.docker/config.json
echo "    ✓ Credenciales copiadas a ~/.docker/config.json"

# -------------------------------------------------------
# PASO 2: Ejecutar oc-mirror
# -------------------------------------------------------
echo ""
echo "==> [2/4] Iniciando oc-mirror (puede tardar HORAS)"
echo "    Config:  ${IMAGESET_CONFIG}"
echo "    Destino: docker://${REGISTRY_URL}"
echo "    Log:     ${WORK_DIR}/oc-mirror-$(date +%Y%m%d).log"
echo ""

LOG_FILE="${WORK_DIR}/oc-mirror-$(date +%Y%m%d-%H%M%S).log"

oc-mirror \
  --config "${IMAGESET_CONFIG}" \
  docker://${REGISTRY_URL} \
  --dest-skip-tls \
  --dest-use-http \
  --ignore-history \
  --verbose 3 \
  2>&1 | tee "${LOG_FILE}"

echo ""
echo "==> [3/4] Mirroring finalizado."
echo "    Log guardado en: ${LOG_FILE}"

# -------------------------------------------------------
# PASO 3: Localizar archivos IDMS generados
# -------------------------------------------------------
echo ""
echo "==> [4/4] Buscando archivos de configuración generados por oc-mirror"

RESULTS_DIR=$(find "${WORK_DIR}" -name "results-*" -type d 2>/dev/null | sort | tail -1)

if [ -n "${RESULTS_DIR}" ]; then
  echo "    Directorio de resultados: ${RESULTS_DIR}"
  echo ""
  ls -lh "${RESULTS_DIR}/"

  mkdir -p "${WORK_DIR}/mirror-configs"
  cp "${RESULTS_DIR}"/*.yaml "${WORK_DIR}/mirror-configs/" 2>/dev/null || true
  cp "${RESULTS_DIR}"/*.json "${WORK_DIR}/mirror-configs/" 2>/dev/null || true

  echo ""
  echo "    Archivos copiados a ${WORK_DIR}/mirror-configs/:"
  ls -lh "${WORK_DIR}/mirror-configs/"

  IDMS_FILE=$(find "${RESULTS_DIR}" -name "imageDigestMirrorSet*.yaml" | head -1)
  if [ -n "${IDMS_FILE}" ]; then
    echo ""
    echo "    ============================================="
    echo "    IDMS para pegar en Assisted Installer UI:"
    echo "    (Sección: Mirror Settings)"
    echo "    ============================================="
    cat "${IDMS_FILE}"
  fi
else
  echo "    ADVERTENCIA: No se encontró directorio results-* en ${WORK_DIR}"
  echo "    Buscá manualmente: find ${WORK_DIR} -name '*.yaml'"
fi

echo ""
echo "============================================="
echo " Mirror completo."
echo " Próximo paso: bash ${WORK_DIR}/03-verify-mirror.sh"
echo "============================================="
