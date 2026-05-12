#!/bin/bash
# =============================================================
# 04-show-idms.sh
# Muestra el ICSP/IDMS y pull-secret para pegar en Assisted Installer
# Ejecutar como: bash /root/OC-Mirror/04-show-idms.sh
# =============================================================

WORK_DIR="/root/OC-Mirror"
REGISTRY_URL="172.18.194.190:5000"
RESULTS_DIR=$(find "${WORK_DIR}" -name "results-*" -type d 2>/dev/null | sort | tail -1)

cd "${WORK_DIR}"

echo "=========================================="
echo " Configuración para Assisted Installer"
echo " Registry: http://${REGISTRY_URL}"
echo "=========================================="

# -------------------------------------------------------
# Buscar archivo de mirror (IDMS o ICSP)
# -------------------------------------------------------
# IDMS = formato nuevo (oc-mirror v2 / OCP >= 4.14)
# ICSP = formato viejo (oc-mirror v1 / esta versión)
MIRROR_FILE=$(find "${RESULTS_DIR}" \
  \( -name "imageDigestMirrorSet*.yaml" -o -name "imageContentSourcePolicy*.yaml" \) \
  2>/dev/null | head -1)

echo ""
echo "--- PASO 1: Archivo de Mirror para Assisted Installer ---"
echo "    (Pegalo en 'Mirror Settings' de la UI)"
echo ""

if [ -n "${MIRROR_FILE}" ] && [ -f "${MIRROR_FILE}" ]; then
  FILE_TYPE=$(basename "${MIRROR_FILE}")
  echo "    Archivo: ${MIRROR_FILE}"
  echo "    Tipo: ${FILE_TYPE}"
  echo ""
  echo "    ============================================="
  cat "${MIRROR_FILE}"
  echo "    ============================================="
  cp "${MIRROR_FILE}" "${WORK_DIR}/mirror-config-para-UI.yaml"
  echo ""
  echo "    Copia guardada en: ${WORK_DIR}/mirror-config-para-UI.yaml"
else
  echo "    ERROR: No se encontró IDMS ni ICSP en ${RESULTS_DIR}"
  echo "    Contenido:"
  ls -lh "${RESULTS_DIR}/" 2>/dev/null
fi

# -------------------------------------------------------
# Repositorios en el registry
# -------------------------------------------------------
echo ""
echo "--- INFO: Repositorios en el registry ---"
REPO_COUNT=$(curl -s "http://${REGISTRY_URL}/v2/_catalog" | jq '.repositories | length' 2>/dev/null || echo 0)
echo "    Total: ${REPO_COUNT} repositorios"
curl -s "http://${REGISTRY_URL}/v2/_catalog" | jq -r '.repositories[]' 2>/dev/null | sed 's/^/    /'

# -------------------------------------------------------
# Pull secret
# -------------------------------------------------------
echo ""
echo "--- PASO 2: Pull Secret para el cluster ---"
echo ""
echo "    RECOMENDADO: usá tu pull-secret ORIGINAL de Red Hat"
echo "    (/root/pull-secret.json) — tiene acceso a todos los"
echo "    registries y es el que espera la UI del Assisted Installer."
echo ""
echo "    Si el cluster es 100%% offline, usá este pull-secret mínimo:"
echo ""
PULL_LOCAL="{\"auths\":{\"${REGISTRY_URL}\":{\"auth\":\"$(echo -n 'unused:unused' | base64 -w0)\",\"email\":\"admin@local\"}}}"
echo "    ${PULL_LOCAL}"
echo "${PULL_LOCAL}" > "${WORK_DIR}/pull-secret-offline.json"
echo ""
echo "    Guardado en: ${WORK_DIR}/pull-secret-offline.json"

# -------------------------------------------------------
# Instrucciones finales
# -------------------------------------------------------
echo ""
echo "=========================================="
echo " Pasos en Assisted Installer"
echo " http://172.18.194.190:8080"
echo "=========================================="
echo " 1. Crear Cluster → OCP 4.15"
echo " 2. Pull Secret → pegá /root/pull-secret.json"
echo " 3. Mirror Settings → pegá el YAML del PASO 1"
echo " 4. Add Hosts → descargar Discovery ISO"
echo " 5. Bootear los nodos con la ISO"
echo "=========================================="
