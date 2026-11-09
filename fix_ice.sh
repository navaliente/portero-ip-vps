#!/bin/bash
curl -s https://raw.githubusercontent.com/navaliente/portero-ip-vps/main/asterisk/pjsip.conf -o /etc/asterisk/pjsip.conf
sed -i "s/TU_IP_PUBLICA_VPS/138.219.41.163/g" /etc/asterisk/pjsip.conf
sed -i "s/CAMBIAR_CLAVE_PORTERO_8000/uJb2YSICXu3Q/g" /etc/asterisk/pjsip.conf
sed -i "s/CAMBIAR_CLAVE_DEPTO_101/dRNLgy0xrANn/g" /etc/asterisk/pjsip.conf
sed -i "s/CAMBIAR_CLAVE_DEPTO_102/0FAPVUVOiMTY/g" /etc/asterisk/pjsip.conf
sed -i "s/CAMBIAR_CLAVE_DEPTO_201/MCR3Yupj6T3k/g" /etc/asterisk/pjsip.conf
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
