#!/usr/bin/env bash
# =============================================================================
# INSTALADOR DEL PANEL WEB DE ADMINISTRACIÓN Y SERVIDOR QR (PUERTO 8088)
# Crea el servicio systemd 'portero-panel' (~12 MB RAM, Python 3 nativo)
# =============================================================================

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
   echo "[ERROR] Ejecuta este script con sudo: sudo bash scripts/install_panel_admin.sh"
   exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

PUBLIC_IP=$(curl -4 -s https://ifconfig.me || curl -4 -s https://api.ipify.org)
PANEL_PASS="${1:-$(openssl rand -base64 10 | tr -dc 'a-zA-Z0-9' | head -c 10)}"

# Detener el http.server estático anterior si estaba corriendo en el 8088
pkill -f "http.server 8088" 2>/dev/null || true

ufw allow 8088/tcp comment "Panel Web Admin y QR Portero IP"

cat > /etc/systemd/system/portero-panel.service <<EOF
[Unit]
Description=Panel Web de Administracion y QR para Portero IP (KD9203 + Asterisk)
After=network.target asterisk.service

[Service]
Type=simple
User=root
Environment="PANEL_PORT=8088"
Environment="PANEL_USER=admin"
Environment="PANEL_PASS=${PANEL_PASS}"
Environment="VPS_IP=${PUBLIC_IP}"
WorkingDirectory=${PROJECT_DIR}
ExecStart=/usr/bin/python3 ${PROJECT_DIR}/panel-admin/app.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now portero-panel.service

if [[ -f /root/credenciales_portero.txt ]]; then
    cat >> /root/credenciales_portero.txt <<EOF

--- PANEL WEB DE ADMINISTRACIÓN ---
URL Panel : http://${PUBLIC_IP}:8088/admin
Usuario   : admin
Contraseña: ${PANEL_PASS}
EOF
fi

echo "=================================================================="
echo "  PANEL WEB LIGERO INSTALADO Y ACTIVO"
echo "=================================================================="
echo "  URL Panel Web : http://${PUBLIC_IP}:8088/admin"
echo "  Usuario Admin : admin"
echo "  Clave Admin   : ${PANEL_PASS}"
echo "=================================================================="

