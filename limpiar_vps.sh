#!/bin/bash
echo "=== 1. ESPACIO EN DISCO ANTES ==="
df -h /

echo "=== 2. CARPETAS QUE MAS ESPACIO OCUPAN ==="
du -h --max-depth=2 /var /home /opt /usr 2>/dev/null | sort -hr | head -n 15

echo "=== 3. LIMPIEZA SEGURA DE LOGS Y CACHE ==="
apt-get clean
journalctl --vacuum-time=2d 2>/dev/null || true
find /var/log -type f \( -name "*.gz" -o -name "*.[0-9]" -o -name "*.old" \) -delete 2>/dev/null || true
truncate -s 0 /var/log/asterisk/messages /var/log/asterisk/full /var/log/syslog 2>/dev/null || true
rm -rf /tmp/* 2>/dev/null || true

echo "=== 4. ESPACIO EN DISCO DESPUES ==="
df -h /

echo "=== 5. ACTUALIZANDO PANEL Y /privacidad ==="
curl -sL https://raw.githubusercontent.com/navaliente/portero-ip-vps/main/panel-admin/app.py -o /opt/portero-ip-vps/panel-admin/app.py
python3 -m py_compile /opt/portero-ip-vps/panel-admin/app.py && systemctl restart portero-panel
echo "--- LISTO: DISCO LIBERADO Y PANEL ACTUALIZADO ---"
