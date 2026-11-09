#!/usr/bin/env bash
# =============================================================================
# GENERADOR DE CÓDIGO QR DE AUTOPROVISIONAMIENTO PARA VECINOS (APP LINPHONE)
# Uso: sudo bash scripts/generar_qr_vecino.sh <NRO_DEPTO>
# Ejemplo: sudo bash scripts/generar_qr_vecino.sh 101
#
# El vecino abre la app Linphone -> Asistente -> Obtener configuración remota
# -> Escanear código QR, ¡y su celular queda configurado con Video H.264,
# Proxy Push y apertura con '#' en 1 segundo!
# =============================================================================

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
   echo "[ERROR] Ejecuta este script con sudo: sudo bash scripts/generar_qr_vecino.sh <NRO_DEPTO>"
   exit 1
fi

EXTEN="${1:-}"
if [[ -z "$EXTEN" ]]; then
    echo "Uso: sudo bash $0 <NRO_DEPTO>"
    echo "Ejemplo: sudo bash $0 101"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Buscar la contraseña de la extensión en los archivos de Asterisk
PASS=$(awk "/^\[${EXTEN}-auth\]/{flag=1;next}/^\[/{flag=0}flag" /etc/asterisk/pjsip.conf /etc/asterisk/pjsip_vecinos_extra.conf 2>/dev/null | grep -E "^password=" | head -n1 | cut -d'=' -f2 | tr -d '[:space:]')

if [[ -z "$PASS" ]]; then
    echo "[ERROR] No se encontró el departamento ${EXTEN} en /etc/asterisk/pjsip.conf."
    echo "Primero créalo con: sudo bash scripts/agregar_vecino.sh ${EXTEN}"
    exit 1
fi

PUBLIC_IP=$(curl -4 -s https://ifconfig.me || curl -4 -s https://api.ipify.org)
PROV_DIR="/var/www/portero-prov"
mkdir -p "$PROV_DIR"

# Generar un token único para que la URL de aprovisionamiento sea secreta
TOKEN=$(echo -n "${EXTEN}:${PASS}:${PUBLIC_IP}" | sha256sum | head -c 24)
XML_FILE="${PROV_DIR}/depto_${EXTEN}_${TOKEN}.xml"

sed -e "s/__EXTEN__/${EXTEN}/g" \
    -e "s/__PASSWORD__/${PASS}/g" \
    -e "s/__VPS_IP__/${PUBLIC_IP}/g" \
    "$PROJECT_DIR/push/linphone-provisioning-template.xml" > "$XML_FILE"

# Levantar micro-servidor HTTP en puerto 8088 si no está corriendo
if ! pgrep -f "http.server 8088" &>/dev/null; then
    nohup python3 -m http.server 8088 --directory "$PROV_DIR" >/var/log/portero-prov.log 2>&1 &
fi

PROV_URL="http://${PUBLIC_IP}:8088/depto_${EXTEN}_${TOKEN}.xml"

echo "=================================================================="
echo "  AUTOPROVISIONAMIENTO QR PARA DEPARTAMENTO ${EXTEN} (LINPHONE)"
echo "=================================================================="
echo "  Extensión SIP : ${EXTEN}"
echo "  Contraseña    : ${PASS}"
echo "  Proxy Push    : ${PUBLIC_IP}:5062 (TCP)"
echo "  URL Remota    : ${PROV_URL}"
echo "=================================================================="
echo ""
echo "Instrucciones para el vecino en la App Linphone:"
echo "  1. Abrir Linphone -> Menú (≡) -> Asistente -> Obtener configuración remota"
echo "  2. Tocar el ícono de Escanear QR (o pegar la URL Remota) y aplicar."
echo ""

if command -v qrencode &>/dev/null; then
    qrencode -t ANSIUTF8 "$PROV_URL"
    qrencode -o "${PROV_DIR}/qr_${EXTEN}.png" -s 8 "$PROV_URL"
    echo "[OK] Imagen QR guardada también en: ${PROV_DIR}/qr_${EXTEN}.png"
else
    echo "[TIP] Instala 'qrencode' (sudo apt install qrencode) para ver el QR en la terminal."
fi

