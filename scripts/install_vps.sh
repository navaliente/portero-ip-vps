#!/usr/bin/env bash
# =============================================================================
# INSTALADOR AUTOMÁTICO DE VPS PARA VIDEOPORTERO IP (KD9203 + ASTERISK)
# Compatible con: Ubuntu 22.04 / 24.04 LTS y Debian 12
# Uso: sudo bash scripts/install_vps.sh [DOMINIO_OPCIONAL_PARA_LETSENCRYPT]
# =============================================================================

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
   echo "[ERROR] Este script debe ejecutarse como root (sudo bash scripts/install_vps.sh)"
   exit 1
fi

DOMINIO="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "=================================================================="
echo "  INSTALADOR DE CENTRAL PBX ASTERISK PARA PORTERO IP (KD9203)"
echo "=================================================================="

# 1. Detectar IP pública fija del VPS
PUBLIC_IP=$(curl -4 -s https://ifconfig.me || curl -4 -s https://api.ipify.org)
if [[ -z "$PUBLIC_IP" ]]; then
    echo "[ERROR] No se pudo detectar la IPv4 pública automáticamente."
    read -rp "Ingresa la IPv4 pública de este VPS: " PUBLIC_IP
fi
echo "[INFO] IP Pública detectada: $PUBLIC_IP"

# 2. Instalar paquetes necesarios
echo "[INFO] Actualizando repositorios e instalando Asterisk, UFW, Fail2ban y Certbot..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y asterisk ufw fail2ban certbot openssl curl

# 3. Generar contraseñas seguras para el portero y vecinos iniciales
PASS_8000=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 12)
PASS_101=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 12)
PASS_102=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 12)
PASS_201=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 12)

# 4. Configurar certificados SSL/TLS para SIP TLS (Puerto 5061)
mkdir -p /etc/asterisk/keys
if [[ -n "$DOMINIO" ]]; then
    echo "[INFO] Solicitando certificado Let's Encrypt para $DOMINIO..."
    certbot certonly --standalone -d "$DOMINIO" --non-interactive --agree-tos --register-unsafely-without-email || true
    if [[ -f "/etc/letsencrypt/live/$DOMINIO/fullchain.pem" ]]; then
        cp "/etc/letsencrypt/live/$DOMINIO/fullchain.pem" /etc/asterisk/keys/asterisk.pem
        cp "/etc/letsencrypt/live/$DOMINIO/privkey.pem" /etc/asterisk/keys/asterisk.key
    fi
fi

# Si no hay dominio o falló Let's Encrypt, generar certificado autofirmado para TLS
if [[ ! -f /etc/asterisk/keys/asterisk.pem ]]; then
    echo "[INFO] Generando certificado TLS autofirmado para SIP seguro (5061)..."
    openssl req -new -x509 -days 3650 -nodes \
        -subj "/CN=${PUBLIC_IP}/O=PorteroIP" \
        -out /etc/asterisk/keys/asterisk.pem \
        -keyout /etc/asterisk/keys/asterisk.key
fi
chown -R asterisk:asterisk /etc/asterisk/keys
chmod 600 /etc/asterisk/keys/*

# 5.Respaldar configuración original y copiar nueva configuración
echo "[INFO] Configurando archivos de Asterisk en /etc/asterisk..."
mkdir -p /etc/asterisk/backup_original
cp -f /etc/asterisk/pjsip.conf /etc/asterisk/backup_original/ 2>/dev/null || true
cp -f /etc/asterisk/extensions.conf /etc/asterisk/backup_original/ 2>/dev/null || true
cp -f /etc/asterisk/rtp.conf /etc/asterisk/backup_original/ 2>/dev/null || true
cp -f /etc/asterisk/logger.conf /etc/asterisk/backup_original/ 2>/dev/null || true

cp "$PROJECT_DIR/asterisk/pjsip.conf" /etc/asterisk/pjsip.conf
cp "$PROJECT_DIR/asterisk/extensions.conf" /etc/asterisk/extensions.conf
cp "$PROJECT_DIR/asterisk/rtp.conf" /etc/asterisk/rtp.conf
cp "$PROJECT_DIR/asterisk/http.conf" /etc/asterisk/http.conf
cp "$PROJECT_DIR/asterisk/logger.conf" /etc/asterisk/logger.conf
touch /etc/asterisk/pjsip_vecinos_extra.conf

# Reemplazar IP pública y contraseñas generadas en pjsip.conf
sed -i "s/TU_IP_PUBLICA_VPS/${PUBLIC_IP}/g" /etc/asterisk/pjsip.conf
sed -i "s/CAMBIAR_CLAVE_PORTERO_8000/${PASS_8000}/g" /etc/asterisk/pjsip.conf
sed -i "s/CAMBIAR_CLAVE_DEPTO_101/${PASS_101}/g" /etc/asterisk/pjsip.conf
sed -i "s/CAMBIAR_CLAVE_DEPTO_102/${PASS_102}/g" /etc/asterisk/pjsip.conf
sed -i "s/CAMBIAR_CLAVE_DEPTO_201/${PASS_201}/g" /etc/asterisk/pjsip.conf

chown -R asterisk:asterisk /etc/asterisk

# 6. Configurar Firewall (UFW)
echo "[INFO] Configurando Firewall UFW..."
ufw allow 22/tcp comment "SSH"
ufw allow 5060/udp comment "SIP UDP"
ufw allow 5060/tcp comment "SIP TCP"
ufw allow 5061/tcp comment "SIP TLS"
ufw allow 8086/tcp comment "Asterisk WS (App Movil)"
ufw allow 8089/tcp comment "Asterisk WSS (App Movil Segura)"
ufw allow 10000:20000/udp comment "RTP Audio y Video H264"
ufw --force enable

# 7. Configurar Fail2ban contra ataques de fuerza bruta SIP
echo "[INFO] Configurando Fail2ban para proteger Asterisk..."
cat > /etc/fail2ban/jail.d/asterisk-portero.conf <<EOF
[asterisk]
enabled  = true
port     = 5060,5061
protocol = all
filter   = asterisk
logpath  = /var/log/asterisk/security
           /var/log/asterisk/messages
maxretry = 4
findtime = 600
bantime  = 86400
EOF

systemctl enable fail2ban
systemctl restart fail2ban

# 8. Reiniciar Asterisk y guardar credenciales
systemctl enable asterisk
systemctl restart asterisk

CRED_FILE="/root/credenciales_portero.txt"
cat > "$CRED_FILE" <<EOF
==================================================================
  CREDENCIALES DEL SERVIDOR ASTERISK (PORTERO IP KD9203)
==================================================================
Servidor SIP (IP Pública) : ${PUBLIC_IP}
Puerto SIP UDP/TCP        : 5060
Puerto SIP TLS            : 5061
Codec de Video            : H.264
Apertura de Puerta (DTMF) : # (RFC4733 / SIP INFO)

--- FRENTE DE CALLE (KD9203) ---
Extensión / Usuario : 8000
Contraseña SIP      : ${PASS_8000}

--- VECINOS INICIALES ---
Depto 101 -> Usuario: 101 | Contraseña: ${PASS_101}
Depto 102 -> Usuario: 102 | Contraseña: ${PASS_102}
Depto 201 -> Usuario: 201 | Contraseña: ${PASS_201}
==================================================================
EOF
chmod 600 "$CRED_FILE"

cat "$CRED_FILE"
echo ""
echo "[OK] Instalación completada. Credenciales guardadas en: $CRED_FILE"
echo "[TIP] Para agregar nuevos departamentos usa: sudo bash scripts/agregar_vecino.sh <NRO_DEPTO>"

