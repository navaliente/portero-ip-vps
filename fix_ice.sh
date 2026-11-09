#!/bin/bash
curl -s https://raw.githubusercontent.com/navaliente/portero-ip-vps/main/asterisk/pjsip.conf -o /etc/asterisk/pjsip.conf
sed -i "s/TU_IP_PUBLICA_VPS/138.219.41.163/g" /etc/asterisk/pjsip.conf
sed -i "s/CAMBIAR_CLAVE_PORTERO_8000/uJb2YSICXu3Q/g" /etc/asterisk/pjsip.conf
sed -i "s/CAMBIAR_CLAVE_DEPTO_101/dRNLgy0xrANn/g" /etc/asterisk/pjsip.conf
sed -i "s/CAMBIAR_CLAVE_DEPTO_102/0FAPVUVOiMTY/g" /etc/asterisk/pjsip.conf
sed -i "s/CAMBIAR_CLAVE_DEPTO_201/MCR3Yupj6T3k/g" /etc/asterisk/pjsip.conf
asterisk -rx "module reload res_pjsip.so"
echo "--- LISTO: PJSIP ACTUALIZADO SIN ICE ---"
