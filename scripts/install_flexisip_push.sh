#!/usr/bin/env bash
# =============================================================================
# INSTALADOR DEL PROXY PUSH (FLEXISIP) EN EL MISMO VPS JUNTO A ASTERISK
# Puertos de Flexisip:
#   - 5062 (UDP/TCP): SIP con soporte Push para celulares
#   - 5063 (TLS)    : SIP Seguro con soporte Push para celulares
# Asterisk permanece en 5060 (donde conecta el frente KD9203 y hacia donde
# Flexisip reenvía las llamadas y registros en 127.0.0.1:5060).
# =============================================================================

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
   echo "[ERROR] Este script debe ejecutarse como root: sudo bash scripts/install_flexisip_push.sh"
   exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

PUBLIC_IP=$(curl -4 -s https://ifconfig.me || curl -4 -s https://api.ipify.org)
if [[ -z "$PUBLIC_IP" ]]; then
    read -rp "Ingresa la IPv4 pública de este VPS: " PUBLIC_IP
fi

echo "=================================================================="
echo "  CONFIGURANDO PROXY PUSH (FLEXISIP) EN EL VPS ($PUBLIC_IP)"
echo "=================================================================="

# 1. Crear directorios de configuración de Flexisip y credenciales Push (FCM / APNs)
mkdir -p /etc/flexisip/push
mkdir -p /var/lib/asterisk/agi-bin

# Copiar configuración de Flexisip y reemplazar IP pública
cp "$PROJECT_DIR/push/flexisip.conf" /etc/flexisip/flexisip.conf
sed -i "s/TU_IP_PUBLICA_VPS/${PUBLIC_IP}/g" /etc/flexisip/flexisip.conf

# Copiar script AGI de Push auxiliar
cp "$PROJECT_DIR/push/push_wakeup.py" /var/lib/asterisk/agi-bin/push_wakeup.py
chmod +x /var/lib/asterisk/agi-bin/push_wakeup.py
chown asterisk:asterisk /var/lib/asterisk/agi-bin/push_wakeup.py 2>/dev/null || true

if [[ ! -f /etc/asterisk/push_devices.json ]]; then
    echo '{}' > /etc/asterisk/push_devices.json
    chown asterisk:asterisk /etc/asterisk/push_devices.json 2>/dev/null || true
fi

# 2. Abrir puertos del Proxy Push en el Firewall UFW (5062 SIP y 5063 SIPS/TLS)
echo "[INFO] Abriendo puertos 5062 (UDP/TCP) y 5063 (TLS) en UFW..."
ufw allow 5062/udp comment "Flexisip Push Proxy UDP"
ufw allow 5062/tcp comment "Flexisip Push Proxy TCP"
ufw allow 5063/tcp comment "Flexisip Push Proxy TLS"
ufw allow 8088/tcp comment "Provisioning QR XML para Linphone"

# 3. Instalar Docker (si no está instalado) para correr la imagen oficial de Flexisip
# en modo host (compartiendo 127.0.0.1 con Asterisk sin sobrecarga ni conflictos de librerías)
if ! command -v docker &>/dev/null; then
    echo "[INFO] Instalando Docker y herramientas QR (qrencode, python3)..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y docker.io qrencode python3
    systemctl enable --now docker
else
    apt-get install -y qrencode python3
fi

# 4. Desplegar contenedor de Flexisip en modo red host (comparte localhost con Asterisk)
echo "[INFO] Iniciando servicio Flexisip Push Proxy..."
docker rm -f flexisip-portero 2>/dev/null || true

docker run -d \
    --name flexisip-portero \
    --restart unless-stopped \
    --network host \
    -v /etc/flexisip/flexisip.conf:/etc/flexisip/flexisip.conf:ro \
    -v /etc/flexisip/push:/etc/flexisip/push:ro \
    -v /etc/asterisk/keys:/etc/asterisk/keys:ro \
    belledonnecommunications/flexisip:latest \
    flexisip --configfile /etc/flexisip/flexisip.conf || {
        echo "[AVISO] Si la imagen de Docker Hub requiere login o tag específico, el archivo /etc/flexisip/flexisip.conf ya quedó listo."
    }

# 5. Actualizar Asterisk con la ruta hacia el Proxy Push
cp "$PROJECT_DIR/asterisk/extensions.conf" /etc/asterisk/extensions.conf
systemctl reload asterisk 2>/dev/null || true

echo ""
echo "=================================================================="
echo "  PROXY PUSH FLEXISIP CONFIGURADO EN EL MISMO VPS"
echo "=================================================================="
echo "  - Frente KD9203 conecta a : ${PUBLIC_IP}:5060 (Asterisk directo)"
echo "  - App de Vecinos conecta a: ${PUBLIC_IP}:5062 (TCP/UDP) o :5063 (TLS)"
echo "  - Carpeta para llaves FCM : /etc/flexisip/push/"
echo "=================================================================="
echo "[TIP] Genera códigos QR de configuración automática para los vecinos con:"
echo "      sudo bash scripts/generar_qr_vecino.sh 101"

