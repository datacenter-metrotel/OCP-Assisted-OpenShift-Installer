#!/bin/bash
# =============================================================
# 03-verify-mirror.sh
# Verifica que el mirror esté completo y accesible
# Ejecutar como: bash /root/OC-Mirror/03-verify-mirror.sh
# =============================================================

WORK_DIR="/root/OC-Mirror"
REGISTRY_URL="172.18.194.190:5000"
OCP_VERSION="4.15"

cd "${WORK_DIR}"

echo "=========================================="
echo " Verificación del Mirror OCP ${OCP_VERSION}"
echo " Registry: http://${REGISTRY_URL}"
echo "=========================================="

ERRORS=0

# 1. Registry responde
echo ""
echo "[1] Conectividad al registry local"
if curl -s --max-time 5 "http://${REGISTRY_URL}/v2/" | grep -q "{}"; then
  echo "    ✓ Registry accesible"
else
  echo "    ✗ Registry NO responde"
  ((ERRORS++))
fi

# 2. Catálogo no vacío
echo ""
echo "[2] Repositorios en el registry"
REPO_COUNT=$(curl -s "http://${REGISTRY_URL}/v2/_catalog" | jq '.repositories | length' 2>/dev/null || echo 0)
echo "    Total repositorios: ${REPO_COUNT}"
if [ "${REPO_COUNT}" -gt 0 ]; then
  echo "    ✓ Registry contiene imágenes"
  echo ""
  echo "    Primeros 15 repositorios:"
  curl -s "http://${REGISTRY_URL}/v2/_catalog" | jq -r '.repositories[]' | head -15 | sed 's/^/      /'
else
  echo "    ✗ El registry está vacío — el mirroring puede no haber completado"
  ((ERRORS++))
fi

# 3. Tags de release OCP presentes
echo ""
echo "[3] Tags de release OCP ${OCP_VERSION}"
for REPO in "openshift/release-images" "openshift-release-dev/ocp-release"; do
  TAGS=$(curl -s "http://${REGISTRY_URL}/v2/${REPO}/tags/list" 2>/dev/null \
    | jq -r '.tags[]?' 2>/dev/null | grep "^${OCP_VERSION}" | head -3)
  if [ -n "${TAGS}" ]; then
    echo "    ✓ ${REPO}:"
    echo "${TAGS}" | sed 's/^/        /'
  fi
done

# 4. Verificar con skopeo
echo ""
echo "[4] Verificación con skopeo"
RELEASE_TAG=$(curl -s "http://${REGISTRY_URL}/v2/openshift/release-images/tags/list" 2>/dev/null \
  | jq -r '.tags[]?' 2>/dev/null | grep "^${OCP_VERSION}" | head -1)

if [ -n "${RELEASE_TAG}" ]; then
  if skopeo inspect --tls-verify=false \
     "docker://${REGISTRY_URL}/openshift/release-images:${RELEASE_TAG}" \
     > /dev/null 2>&1; then
    echo "    ✓ skopeo puede inspeccionar: openshift/release-images:${RELEASE_TAG}"
  else
    echo "    ✗ skopeo no pudo inspeccionar la imagen"
    ((ERRORS++))
  fi
else
  echo "    SKIP: No se encontraron tags de release para inspeccionar"
fi

# 5. Archivos IDMS generados
echo ""
echo "[5] Archivos de configuración del mirror"
RESULTS_DIR=$(find "${WORK_DIR}" -name "results-*" -type d 2>/dev/null | sort | tail -1)
if [ -n "${RESULTS_DIR}" ]; then
  echo "    ✓ Directorio de resultados: ${RESULTS_DIR}"
  find "${RESULTS_DIR}" -name "*.yaml" | while read f; do
    echo "      $(basename ${f})"
  done
else
  echo "    ✗ No se encontró directorio results-* en ${WORK_DIR}"
  ((ERRORS++))
fi

# 6. Espacio en disco
echo ""
echo "[6] Uso de disco"
du -sh /opt/registry/ 2>/dev/null | awk '{print "    Usado en /opt/registry: " $1}'
df -h /opt/registry/ | awk 'NR==2 {print "    Libre: " $4 " de " $2}'
du -sh "${WORK_DIR}/" 2>/dev/null | awk '{print "    Usado en WORK_DIR: " $1}'

# 7. URL de catálogo completo
echo ""
echo "[7] URLs útiles"
echo "    Catálogo completo: http://${REGISTRY_URL}/v2/_catalog"
echo "    Logs del mirror:   ls -lh ${WORK_DIR}/oc-mirror-*.log"

# Resumen
echo ""
echo "=========================================="
if [ "${ERRORS}" -eq 0 ]; then
  echo " ✓ Verificación EXITOSA — Mirror listo"
  echo ""
  echo " Próximo paso: bash ${WORK_DIR}/04-show-idms.sh"
else
  echo " ✗ Se encontraron ${ERRORS} error(es)"
  echo "   Revisá el log: ls -lh ${WORK_DIR}/oc-mirror-*.log"
fi
echo "=========================================="
