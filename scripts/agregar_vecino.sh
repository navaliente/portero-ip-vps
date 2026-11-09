#!/usr/bin/env bash
# =============================================================================
# SCRIPT PARA AGREGAR UN NUEVO DEPARTAMENTO / VECINO EN ASTERISK
# Uso: sudo bash scripts/agregar_vecino.sh <NUMERO_DEPTO> [CLAVE_OPCIONAL]
# Ejemplo: sudo bash scripts/agregar_vecino.sh 304
# =============================================================================

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
   echo "[ERROR] Ejecuta este script con sudo: sudo bash scripts/agregar_vecino.sh <NRO_DEPTO>"
   exit 1
fi

EXTEN="${1:-}"
if [[ -z "$EXTEN" || ! "$EXTEN" =~ ^[1-7][0-9]{2}$ ]]; then
    echo "Uso: sudo bash $0 <NRO_DEPTO_3_DIGITOS> [CLAVE_OPCIONAL]"
    echo "Ejemplo: sudo bash $0 301"
    echo "(El número debe estar entre 100 y 799 según el plan de marcado)"
    exit 1
fi

PASS="${2:-$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 12)}"
EXTRA_FILE="/etc/asterisk/pjsip_vecinos_extra.conf"
touch "$EXTRA_FILE"

if grep -q "^\[${EXTEN}\]" /etc/asterisk/pjsip.conf "$EXTRA_FILE" 2>/dev/null; then
    echo "[ERROR] El departamento ${EXTEN} ya existe en la configuración de Asterisk."
    exit 1
fi

cat >> "$EXTRA_FILE" <<EOF

; --- Departamento ${EXTEN} (Agregado el $(date '+%Y-%m-%d %H:%M')) ---
[${EXTEN}](endpoint-base)
auth=${EXTEN}-auth
aors=${EXTEN}
callerid="Depto ${EXTEN}" <${EXTEN}>

[${EXTEN}-webrtc](endpoint-webrtc)
auth=${EXTEN}-auth
aors=${EXTEN}-webrtc
callerid="Depto ${EXTEN} App" <${EXTEN}>

[${EXTEN}-auth](auth-base)
username=${EXTEN}
password=${PASS}

[${EXTEN}](aor-vecino)
[${EXTEN}-webrtc](aor-vecino-webrtc)
EOF

chown asterisk:asterisk "$EXTRA_FILE"
asterisk -rx "module reload res_pjsip.so"

echo "=================================================="
echo "  DEPARTAMENTO ${EXTEN} CREADO EXITOSAMENTE"
echo "=================================================="
echo "Usuario SIP    : ${EXTEN}"
echo "Contraseña SIP : ${PASS}"
echo "Max Celulares  : 5 simultáneos"
echo "=================================================="

if [[ -f /root/credenciales_portero.txt ]]; then
    echo "Depto ${EXTEN} -> Usuario: ${EXTEN} | Contraseña: ${PASS}" >> /root/credenciales_portero.txt
fi

