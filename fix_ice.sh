#!/bin/bash
curl -s https://raw.githubusercontent.com/navaliente/portero-ip-vps/main/asterisk/pjsip.conf -o /etc/asterisk/pjsip.conf
sed -i "s/TU_IP_PUBLICA_VPS/${VPS_IP:-REEMPLAZAR_IP_VPS}/g" /etc/asterisk/pjsip.conf
sed -i "s/CAMBIAR_CLAVE_PORTERO_8000/${PASS_8000:-REEMPLAZAR_CLAVE_8000}/g" /etc/asterisk/pjsip.conf
sed -i "s/CAMBIAR_CLAVE_DEPTO_101/${PASS_101:-REEMPLAZAR_CLAVE_101}/g" /etc/asterisk/pjsip.conf
sed -i "s/CAMBIAR_CLAVE_DEPTO_102/${PASS_102:-REEMPLAZAR_CLAVE_102}/g" /etc/asterisk/pjsip.conf
sed -i "s/CAMBIAR_CLAVE_DEPTO_201/${PASS_201:-REEMPLAZAR_CLAVE_201}/g" /etc/asterisk/pjsip.conf
asterisk -rx "module reload res_pjsip.so"
echo "--- LISTO: PJSIP ACTUALIZADO SIN ICE ---"

# Habilitar SSH root con clave y UFW para poder administrar de forma remota
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
if [ -d /etc/ssh/sshd_config.d ]; then
  echo "PermitRootLogin yes" > /etc/ssh/sshd_config.d/root_login.conf
  echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config.d/root_login.conf
fi
which ufw >/dev/null 2>&1 && ufw allow 22/tcp
systemctl restart ssh || systemctl restart sshd
echo "--- SSH HABILITADO PARA ACCESO DIRECTO ---"
