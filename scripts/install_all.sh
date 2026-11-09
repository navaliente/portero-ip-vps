#!/usr/bin/env bash
# =============================================================================
# INSTALADOR MAESTRO TODO-EN-UNO PARA EL VPS (ETAPAS 3, 4 Y 5)
# Instala y configura en un solo paso:
#   1. Asterisk PBX (PJSIP + H.264 + NAT + WS/WSS + UFW + Fail2ban)
#   2. Proxy Push (Flexisip + push_wakeup.py FCM HTTP v1)
#   3. Panel Web Ligero y Generador de Códigos QR (:8088/admin)
#
# Uso en el VPS:
#   sudo bash scripts/install_all.sh [DOMINIO_OPCIONAL]
# =============================================================================

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
   echo "[ERROR] Ejecuta este script como root: sudo bash scripts/install_all.sh"
   exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOMINIO="${1:-}"

echo "=================================================================="
echo "  INICIANDO INSTALACIÓN COMPLETA DEL VIDEOPORTERO IP EN EL VPS"
echo "=================================================================="

echo ""
echo ">>> [ETAPA 3/5] Instalando Asterisk PBX, Video H.264, UFW y Fail2ban..."
bash "$SCRIPT_DIR/install_vps.sh" "$DOMINIO"

echo ""
echo ">>> [ETAPA 4/5] Instalando Proxy Push (Flexisip + FCM HTTP v1)..."
bash "$SCRIPT_DIR/install_flexisip_push.sh"

echo ""
echo ">>> [ETAPA 5/5] Instalando Panel Web Ligero y Servidor QR (Puerto 8088)..."
bash "$SCRIPT_DIR/install_panel_admin.sh"

echo ""
echo "=================================================================="
echo "  RESUMEN FINAL DE CREDENCIALES Y ACCESOS DEL VPS"
echo "=================================================================="
cat /root/credenciales_portero.txt
echo "=================================================================="

