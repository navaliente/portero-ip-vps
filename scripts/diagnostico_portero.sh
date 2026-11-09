#!/usr/bin/env bash
# =============================================================================
# SCRIPT DE DIAGNÓSTICO Y VERIFICACIÓN DEL VIDEOPORTERO IP EN EL VPS
# Uso: sudo bash scripts/diagnostico_portero.sh
# =============================================================================

set -euo pipefail

echo "=================================================================="
echo "  DIAGNÓSTICO EN VIVO DEL VIDEOPORTERO IP (KD9203 + ASTERISK VPS)"
echo "=================================================================="

echo ""
echo "[1/5] Estado de Servicios principales:"
for svc in asterisk fail2ban portero-panel; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        echo "  [OK] Servicio $svc: ACTIVO"
    else
        echo "  [!!] Servicio $svc: INACTIVO o no instalado"
    fi
done

if command -v docker &>/dev/null && docker ps --format '{{.Names}}' | grep -q "flexisip-portero"; then
    echo "  [OK] Contenedor flexisip-portero (Proxy Push): ACTIVO"
else
    echo "  [--] Contenedor flexisip-portero: No activo en Docker"
fi

echo ""
echo "[2/5] Puertos de Red escuchando (SIP 5060/5061, Push 5062, WS 8080/8089, Panel 8088):"
ss -tulnp | grep -E ":(5060|5061|5062|5063|8080|8088|8089)\b" || echo "  [!!] No se detectaron puertos escuchando"

echo ""
echo "[3/5] Estado de Registro del Frente KD9203 (8000) y Departamentos en Asterisk:"
if command -v asterisk &>/dev/null; then
    asterisk -rx "pjsip show aors"
else
    echo "  [!!] Asterisk no está instalado aún."
fi

echo ""
echo "[4/5] Dispositivos con Token Push registrados (/etc/asterisk/push_devices.json):"
if [[ -f /etc/asterisk/push_devices.json ]]; then
    cat /etc/asterisk/push_devices.json
else
    echo "  (Aún no hay dispositivos registrados en /etc/asterisk/push_devices.json)"
fi

echo ""
echo "[5/5] Protección Fail2ban (IPs bloqueadas en jaula asterisk):"
if command -v fail2ban-client &>/dev/null; then
    fail2ban-client status asterisk 2>/dev/null || echo "  Jaula asterisk aún no activa."
fi

echo "=================================================================="

