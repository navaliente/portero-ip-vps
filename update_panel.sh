#!/bin/bash
curl -sL https://raw.githubusercontent.com/navaliente/portero-ip-vps/main/panel-admin/app.py -o /opt/portero-ip-vps/panel-admin/app.py
python3 -m py_compile /opt/portero-ip-vps/panel-admin/app.py && systemctl restart portero-panel
systemctl status portero-panel --no-pager | head -n 10
echo "--- LISTO: PANEL ADMIN Y WEBAPP ACTUALIZADOS ---"
