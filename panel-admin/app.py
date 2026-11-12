#!/usr/bin/env python3
"""
Panel Web Ligero de Administración y Autoprovisionamiento QR para Portero IP (KD9203 + Asterisk + Flexisip)
Consumo de RAM: ~12 MB (Usa únicamente librería estándar de Python 3, sin dependencias pesadas).

Funciones:
  - Estado en tiempo real del Frente KD9203 (Ext. 8000) y de todos los departamentos (vía `asterisk -rx`).
  - Alta y baja de departamentos en caliente (recarga PJSIP automáticamente).
  - Servidor de autoprovisionamiento XML para la app Linphone (`/prov/<token>.xml`).
  - Generador de Código QR listo para escanear o compartir con cada vecino.
"""

import base64
import hashlib
import html
import http.server
import json
import os
import re
import secrets
import subprocess
import urllib.parse
from datetime import datetime

PORT = int(os.environ.get("PANEL_PORT", "8088"))
ADMIN_USER = os.environ.get("PANEL_USER", "admin")
ADMIN_PASS = os.environ.get("PANEL_PASS", "portero2026")
VPS_IP = os.environ.get("VPS_IP", "127.0.0.1")

BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PJSIP_MAIN = (
    "/etc/asterisk/pjsip.conf"
    if os.path.exists("/etc/asterisk/pjsip.conf")
    else os.path.join(BASE_DIR, "asterisk", "pjsip.conf")
)
PJSIP_EXTRA = (
    "/etc/asterisk/pjsip_vecinos_extra.conf"
    if os.path.exists("/etc/asterisk")
    else os.path.join(BASE_DIR, "asterisk", "pjsip_vecinos_extra.conf")
)
PUSH_DEVICES_FILE = (
    "/etc/asterisk/push_devices.json"
    if os.path.exists("/etc/asterisk")
    else os.path.join(BASE_DIR, "asterisk", "push_devices.json")
)
TEMPLATE_XML = os.path.join(
    BASE_DIR,
    "push",
    "linphone-provisioning-template.xml",
)


def load_push_devices() -> dict[str, list[dict]]:
    if not os.path.exists(PUSH_DEVICES_FILE):
        return {}
    try:
        with open(PUSH_DEVICES_FILE, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}


def save_push_device(exten: str, token: str, platform: str, device_name: str = "") -> None:
    data = load_push_devices()
    devices = data.get(exten, [])
    now_str = datetime.now().strftime("%Y-%m-%d %H:%M")
    devices = [d for d in devices if d.get("token") != token]
    devices.append(
        {
            "token": token,
            "platform": platform,
            "device_name": device_name or platform,
            "updated_at": now_str,
        }
    )
    data[exten] = devices[-5:]  # Máximo 5 dispositivos por departamento
    os.makedirs(os.path.dirname(PUSH_DEVICES_FILE), exist_ok=True)
    with open(PUSH_DEVICES_FILE, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)


def get_base_web_url() -> str:
    domain = os.environ.get("VPS_DOMAIN", "vps-6615824-x.dattaweb.com")
    if domain:
        return f"https://{domain}"
    pub_ip = get_public_ip()
    return f"http://{pub_ip}:{PORT}"


def get_public_ip() -> str:
    if VPS_IP and VPS_IP != "127.0.0.1":
        return VPS_IP
    try:
        out = subprocess.check_output(
            ["curl", "-4", "-s", "--max-time", "3", "https://api.ipify.org"],
            text=True,
        ).strip()
        if out:
            return out
    except Exception:
        pass
    return "127.0.0.1"


def parse_extensions() -> list[dict]:
    """Lee las extensiones y contraseñas desde pjsip.conf y pjsip_vecinos_extra.conf."""
    files = [f for f in (PJSIP_MAIN, PJSIP_EXTRA) if os.path.exists(f)]
    content = ""
    for fpath in files:
        try:
            with open(fpath, "r", encoding="utf-8", errors="ignore") as f:
                content += "\n" + f.read()
        except Exception:
            pass

    auth_blocks = re.findall(
        r"^\[(\d+)-auth\]\s*(.*?)(?=^\[|\Z)", content, flags=re.MULTILINE | re.DOTALL
    )
    aor_status = get_asterisk_aor_status()
    push_db = load_push_devices()

    extensions = []
    pub_ip = get_public_ip()
    base_url = get_base_web_url()
    for exten, body in auth_blocks:
        m_pass = re.search(r"^password\s*=\s*(.+)$", body, flags=re.MULTILINE)
        password = m_pass.group(1).strip() if m_pass else ""
        token = hashlib.sha256(f"{exten}:{password}:{pub_ip}".encode()).hexdigest()[:24]
        status_info = aor_status.get(exten, {"contacts": 0, "status": "Offline"})
        push_count = len(push_db.get(exten, []))
        extensions.append(
            {
                "exten": exten,
                "role": "Frente de Calle KD9203" if exten == "8000" else f"Departamento {exten}",
                "password": password,
                "token": token,
                "prov_url": f"{base_url}/prov/{exten}_{token}.xml",
                "app_config_url": f"{base_url}/api/config/{exten}_{token}.json",
                "webapp_url": f"{base_url}/vecino?exten={exten}&token={token}",
                "contacts": status_info["contacts"],
                "push_count": push_count,
                "status": status_info["status"],
            }
        )

    extensions.sort(key=lambda x: (0 if x["exten"] == "8000" else 1, int(x["exten"])))
    return extensions


def get_asterisk_aor_status() -> dict[str, dict]:
    """Consulta a Asterisk (`pjsip show aors`) cuántos dispositivos están registrados por extensión."""
    result: dict[str, dict] = {}
    try:
        out = subprocess.check_output(
            ["asterisk", "-rx", "pjsip show aors"], text=True, stderr=subprocess.DEVNULL
        )
        # Formato típico: Aor:  101   5
        # Contact:  101/sip:101@...  Avail  ...
        current_aor = None
        for line in out.splitlines():
            m_aor = re.match(r"^\s*Aor:\s+(\d+)(?:-webrtc)?\s+", line)
            if m_aor:
                current_aor = m_aor.group(1)
                if current_aor not in result:
                    result[current_aor] = {"contacts": 0, "status": "Offline"}
                continue
            if current_aor and "Contact:" in line:
                result[current_aor]["contacts"] += 1
                if "Avail" in line or "NonQual" in line:
                    result[current_aor]["status"] = "Online"
    except Exception:
        pass
    return result


def add_neighbor_extension(exten: str, password: str) -> tuple[bool, str]:
    if not re.match(r"^[1-7]\d{2}$", exten):
        return False, "El número de departamento debe tener 3 dígitos (entre 100 y 799)."

    existing = {item["exten"] for item in parse_extensions()}
    if exten in existing:
        return False, f"El departamento {exten} ya existe."

    if not password:
        password = secrets.token_urlsafe(9)[:12]

    os.makedirs(os.path.dirname(PJSIP_EXTRA), exist_ok=True)
    now_str = datetime.now().strftime("%Y-%m-%d %H:%M")
    block = (
        f"\n; --- Departamento {exten} (Agregado desde Panel Web el {now_str}) ---\n"
        f"[{exten}](endpoint-base)\n"
        f"auth={exten}-auth\n"
        f"aors={exten}\n"
        f'callerid="Depto {exten}" <{exten}>\n\n'
        f"[{exten}-webrtc](endpoint-webrtc)\n"
        f"auth={exten}-auth\n"
        f"aors={exten}-webrtc\n"
        f'callerid="Depto {exten} App" <{exten}>\n\n'
        f"[{exten}-auth](auth-base)\n"
        f"username={exten}\n"
        f"password={password}\n\n"
        f"[{exten}](aor-vecino)\n"
        f"[{exten}-webrtc](aor-vecino-webrtc)\n"
    )
    with open(PJSIP_EXTRA, "a", encoding="utf-8") as f:
        f.write(block)

    subprocess.run(["asterisk", "-rx", "module reload res_pjsip.so"], check=False)
    return True, f"Departamento {exten} creado exitosamente."


def delete_neighbor_extension(exten: str) -> tuple[bool, str]:
    if exten == "8000" or not os.path.exists(PJSIP_EXTRA):
        return False, "Solo se pueden eliminar departamentos adicionales creados en pjsip_vecinos_extra.conf."

    with open(PJSIP_EXTRA, "r", encoding="utf-8") as f:
        content = f.read()

    pattern = (
        rf"(?:^;[^\n]*Departamento {re.escape(exten)}[^\n]*\n)?"
        rf"^\[{re.escape(exten)}\]\(endpoint-base\).*?^\[{re.escape(exten)}(?:-webrtc)?\]\(aor-vecino(?:-webrtc)?\)\s*"
    )
    new_content, count = re.subn(pattern, "", content, flags=re.MULTILINE | re.DOTALL)
    if count == 0:
        return False, f"El departamento {exten} está en el archivo base pjsip.conf (no en extras)."

    with open(PJSIP_EXTRA, "w", encoding="utf-8") as f:
        f.write(new_content)

    subprocess.run(["asterisk", "-rx", "module reload res_pjsip.so"], check=False)
    return True, f"Departamento {exten} eliminado."


def generate_provisioning_xml(exten: str, token: str) -> str | None:
    for item in parse_extensions():
        if item["exten"] == exten and item["token"] == token:
            with open(TEMPLATE_XML, "r", encoding="utf-8") as f:
                xml = f.read()
            pub_ip = get_public_ip()
            return (
                xml.replace("__EXTEN__", exten)
                .replace("__PASSWORD__", item["password"])
                .replace("__VPS_IP__", pub_ip)
            )
    return None


class PorteroAdminHandler(http.server.BaseHTTPRequestHandler):
    def check_auth(self) -> bool:
        auth_header = self.headers.get("Authorization", "")
        if not auth_header.startswith("Basic "):
            return False
        try:
            decoded = base64.b64decode(auth_header[6:]).decode("utf-8")
            user, passwd = decoded.split(":", 1)
            return secrets.compare_digest(user, ADMIN_USER) and secrets.compare_digest(
                passwd, ADMIN_PASS
            )
        except Exception:
            return False

    def require_auth(self) -> None:
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="Panel Portero IP"')
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.end_headers()
        self.wfile.write(b"Autenticacion requerida.")

    def do_GET(self) -> None:
        parsed = urllib.parse.urlparse(self.path)

        # Política de Privacidad pública requerida por Google Play Store
        if parsed.path == "/privacidad":
            privacy_html = """<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Política de Privacidad • PorteroCloud</title>
    <style>
        body { font-family: system-ui, -apple-system, sans-serif; background: #060911; color: #e2e8f0; max-width: 760px; margin: 40px auto; padding: 0 20px; line-height: 1.65; }
        h1 { color: #ffffff; font-size: 26px; }
        h2 { color: #818cf8; font-size: 17px; margin-top: 24px; }
        .card { background: #0d1321; border: 1px solid rgba(255,255,255,0.08); border-radius: 16px; padding: 28px; }
    </style>
</head>
<body>
    <div class="card">
        <h1>Política de Privacidad — PorteroCloud</h1>
        <p><strong>Última actualización:</strong> Noviembre 2026 · Paquete: <code>com.navaliente.porteroip</code></p>
        <h2>1. Finalidad de la aplicación</h2>
        <p>PorteroCloud permite a los residentes de un edificio recibir videollamadas desde el frente de calle SIP del consorcio, visualizar en vivo la entrada y accionar la apertura remota de puerta.</p>
        <h2>2. Permisos y datos utilizados</h2>
        <ul>
            <li><strong>Cámara (CAMERA):</strong> Se utiliza únicamente para escanear el código QR de vinculación del departamento y habilitar la transmisión de videoportero cuando el usuario lo inicia.</li>
            <li><strong>Micrófono (RECORD_AUDIO):</strong> Se utiliza exclusivamente durante las llamadas activas entre el residente y el frente de calle para mantener comunicación de voz bidireccional.</li>
            <li><strong>Notificaciones y llamadas entrantes (POST_NOTIFICATIONS / USE_FULL_SCREEN_INTENT):</strong> Necesarios para despertar la pantalla y alertar cuando un visitante presiona el timbre del departamento.</li>
            <li><strong>Almacenamiento local:</strong> La configuración del interno y el historial local de llamadas se guardan únicamente en el dispositivo del usuario.</li>
        </ul>
        <h2>3. Compartición y retención de datos</h2>
        <p>PorteroCloud no vende, alquila ni comparte datos personales, grabaciones de audio ni imágenes con terceros ni con redes publicitarias. La comunicación SIP/WebRTC viaja cifrada hacia la central privada del edificio.</p>
        <h2>4. Contacto y eliminación</h2>
        <p>Para solicitar la baja de su interno o token de notificaciones, comuníquese con la administración de su edificio o escriba a <code>soporte@navaliente</code>.</p>
    </div>
</body>
</html>"""
            body = privacy_html.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        # Endpoint público (con token secreto) para que la app Linphone descargue el XML al escanear el QR
        m_prov = re.match(r"^/prov/(\d+)_([a-f0-9]{24})\.xml$", parsed.path)
        if m_prov:
            exten, token = m_prov.group(1), m_prov.group(2)
            xml_data = generate_provisioning_xml(exten, token)
            if xml_data:
                body = xml_data.encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "application/xml; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            self.send_error(404, "Perfil de aprovisionamiento no encontrado")
            return

        # Endpoint público (con token secreto) en JSON para la App Móvil propia del edificio
        m_json = re.match(r"^/api/config/(\d+)_([a-f0-9]{24})\.json$", parsed.path)
        if m_json:
            exten, token = m_json.group(1), m_json.group(2)
            for item in parse_extensions():
                if item["exten"] == exten and item["token"] == token:
                    pub_ip = get_public_ip()
                    base_url = get_base_web_url()
                    domain = os.environ.get("VPS_DOMAIN", "vps-6615824-x.dattaweb.com")
                    payload = {
                        "exten": exten,
                        "password": item["password"],
                        "sip_host": pub_ip,
                        "sip_port": 5060,
                        "push_proxy_port": 5060,
                        "ws_url": f"wss://{domain}/ws" if domain else f"ws://{pub_ip}:8086/ws",
                        "wss_url": f"wss://{domain}/ws" if domain else f"wss://{pub_ip}:8089/ws",
                        "door_exten": "8000",
                        "dtmf_unlock": "#",
                        "push_register_url": f"{base_url}/api/register-push",
                    }
                    body = json.dumps(payload).encode("utf-8")
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json; charset=utf-8")
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                    return
            self.send_error(404, "Configuracion no encontrada")
            return

        # Vista de la App Móvil / Web App para el Vecino (autenticada por token del departamento)
        if parsed.path == "/vecino":
            qs = urllib.parse.parse_qs(parsed.query)
            exten = qs.get("exten", ["101"])[0]
            token = qs.get("token", [""])[0]
            self.render_neighbor_app(exten, token)
            return

        # El resto del panel requiere usuario y contraseña de administrador
        if not self.check_auth():
            self.require_auth()
            return

        if parsed.path in ("/", "/admin"):
            qs = urllib.parse.parse_qs(parsed.query)
            msg = qs.get("msg", [""])[0]
            err = qs.get("err", [""])[0]
            self.render_dashboard(msg=msg, err=err)
        else:
            self.send_error(404, "Ruta no encontrada")

    def do_POST(self) -> None:
        length = int(self.headers.get("Content-Length", "0"))
        post_data = self.rfile.read(length).decode("utf-8")

        # Endpoint público autenticado por extensión+clave SIP para que la App Móvil registre su token FCM/APNs
        if self.path == "/api/register-push":
            try:
                data = json.loads(post_data)
                exten = str(data.get("exten", "")).strip()
                password = str(data.get("password", "")).strip()
                fcm_token = str(data.get("fcm_token", "")).strip()
                platform = str(data.get("platform", "android")).strip()
                device_name = str(data.get("device_name", "")).strip()

                valid = any(
                    item["exten"] == exten and secrets.compare_digest(item["password"], password)
                    for item in parse_extensions()
                )
                if not valid or not fcm_token:
                    self.send_error(403, "Credenciales SIP invalidas o token vacio")
                    return

                save_push_device(exten, fcm_token, platform, device_name)
                body = json.dumps({"ok": True, "exten": exten}).encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "application/json; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            except Exception as e:
                self.send_error(400, f"Solicitud invalida: {e}")
            return

        if not self.check_auth():
            self.require_auth()
            return

        form = urllib.parse.parse_qs(post_data)

        if self.path == "/admin/add":
            exten = form.get("exten", [""])[0].strip()
            password = form.get("password", [""])[0].strip()
            ok, message = add_neighbor_extension(exten, password)
            param = "msg" if ok else "err"
            self.redirect(f"/admin?{param}={urllib.parse.quote(message)}")
        elif self.path == "/admin/delete":
            exten = form.get("exten", [""])[0].strip()
            ok, message = delete_neighbor_extension(exten)
            param = "msg" if ok else "err"
            self.redirect(f"/admin?{param}={urllib.parse.quote(message)}")
        else:
            self.send_error(404)

    def redirect(self, location: str) -> None:
        self.send_response(303)
        self.send_header("Location", location)
        self.end_headers()

    def render_dashboard(self, msg: str = "", err: str = "") -> None:
        pub_ip = get_public_ip()
        items = parse_extensions()

        total_units = sum(1 for i in items if i["exten"] != "8000")
        online_units = sum(1 for i in items if i["exten"] != "8000" and i["status"] == "Online")
        total_contacts = sum(int(i.get("contacts", 0)) for i in items)
        total_push = sum(int(i.get("push_count", 0)) for i in items)
        door_item = next((i for i in items if i["exten"] == "8000"), None)
        door_online = door_item is not None and door_item.get("status") == "Online"

        rows_html = ""
        for item in items:
            is_door = item["exten"] == "8000"
            is_online = item["status"] == "Online"
            ext_esc = html.escape(item["exten"])
            role_esc = html.escape(item["role"])
            pass_esc = html.escape(item["password"])

            status_dot = (
                '<span class="inline-block w-2 h-2 rounded-full bg-emerald-400 shadow-[0_0_8px_rgba(52,211,153,0.8)]"></span>'
                if is_online
                else '<span class="inline-block w-2 h-2 rounded-full bg-slate-500"></span>'
            )
            status_pill_cls = (
                "bg-emerald-500/10 text-emerald-300 border-emerald-500/25"
                if is_online
                else "bg-slate-800/80 text-slate-400 border-white/10"
            )
            status_text = "En línea" if is_online else "Desconectado"

            avatar_cls = (
                "bg-cyan-500/15 text-cyan-300 border-cyan-500/30"
                if is_door
                else "bg-indigo-500/15 text-indigo-300 border-indigo-500/30"
            )
            avatar_label = (
                '<svg class="w-4 h-4" fill="none" stroke="currentColor" stroke-width="1.8" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M15 10l4.553-2.276A1 1 0 0121 8.618v6.764a1 1 0 01-1.447.894L15 14M5 18h8a2 2 0 002-2V8a2 2 0 00-2-2H5a2 2 0 00-2 2v8a2 2 0 002 2z"/></svg>'
                if is_door
                else ext_esc
            )

            delete_btn = (
                ""
                if is_door
                else f"""
                <form method="POST" action="/admin/delete" class="inline" onsubmit="return confirm('¿Eliminar el departamento {ext_esc}?');">
                    <input type="hidden" name="exten" value="{ext_esc}">
                    <button type="submit" title="Eliminar unidad"
                            class="p-2 text-slate-400 hover:text-rose-400 hover:bg-rose-500/10 rounded-lg border border-transparent hover:border-rose-500/20 transition">
                        <svg class="w-4 h-4" fill="none" stroke="currentColor" stroke-width="1.8" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16"/></svg>
                    </button>
                </form>
                """
            )

            actions_html = (
                '<span class="inline-flex items-center gap-1.5 px-2.5 py-1 rounded-lg bg-white/[0.03] border border-white/10 text-xs text-slate-400 font-mono">Frente Calle • UDP/TCP 5060</span>'
                if is_door
                else f"""
                <div class="inline-flex items-center justify-end gap-1.5">
                    <a href="{html.escape(item['webapp_url'])}" target="_blank"
                       class="inline-flex items-center gap-1.5 px-3 py-1.5 text-xs font-semibold rounded-lg bg-white/[0.05] hover:bg-white/[0.1] text-slate-200 border border-white/10 transition">
                        <svg class="w-3.5 h-3.5 text-emerald-400" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M12 18h.01M8 21h8a2 2 0 002-2V5a2 2 0 00-2-2H8a2 2 0 00-2 2v14a2 2 0 002 2z"/></svg>
                        WebApp
                    </a>
                    <button type="button"
                            onclick="openQR('{ext_esc}', '{html.escape(item['prov_url'])}', '{html.escape(item['app_config_url'])}')"
                            class="inline-flex items-center gap-1.5 px-3 py-1.5 text-xs font-semibold rounded-lg bg-indigo-600/90 hover:bg-indigo-500 text-white shadow-sm shadow-indigo-950/50 transition">
                        <svg class="w-3.5 h-3.5" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M12 4v1m6 11h2m-6 0h-2v4m0-11v3m0 0h.01M12 12h4.01M16 20h4M4 12h4m12 0h.01M5 8h2a1 1 0 001-1V5a1 1 0 00-1-1H5a1 1 0 00-1 1v2a1 1 0 001 1zm12 0h2a1 1 0 001-1V5a1 1 0 00-1-1h-2a1 1 0 00-1 1v2a1 1 0 001 1zM5 20h2a1 1 0 001-1v-2a1 1 0 00-1-1H5a1 1 0 00-1 1v2a1 1 0 001 1z"/></svg>
                        Vincular QR
                    </button>
                    {delete_btn}
                </div>
                """
            )

            rows_html += f"""
            <tr class="unit-row border-b border-white/[0.06] hover:bg-white/[0.025] transition-colors"
                data-search="{ext_esc} {role_esc.lower()}"
                data-status="{'online' if is_online else 'offline'}">
                <td class="py-3.5 px-5">
                    <div class="flex items-center gap-3.5">
                        <div class="w-9 h-9 rounded-xl border {avatar_cls} flex items-center justify-center font-mono text-xs font-bold shrink-0">
                            {avatar_label}
                        </div>
                        <div>
                            <div class="text-sm font-semibold text-white">{role_esc}</div>
                            <div class="text-xs text-slate-500 font-mono">SIP ID: {ext_esc}</div>
                        </div>
                    </div>
                </td>
                <td class="py-3.5 px-5">
                    <div class="inline-flex items-center gap-1.5 bg-[#070B14] border border-white/[0.07] rounded-lg px-2.5 py-1">
                        <span class="pw-text font-mono text-xs text-slate-300 tracking-wider" data-pw="{pass_esc}" data-visible="0">••••••••••••</span>
                        <button type="button" onclick="toggleRowPw(this)" title="Mostrar / ocultar"
                                class="text-slate-500 hover:text-slate-200 p-0.5 transition">
                            <svg class="w-3.5 h-3.5" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M15 12a3 3 0 11-6 0 3 3 0 016 0z"/><path stroke-linecap="round" stroke-linejoin="round" d="M2.458 12C3.732 7.943 7.523 5 12 5c4.478 0 8.268 2.943 9.542 7-1.274 4.057-5.064 7-9.542 7-4.477 0-8.268-2.943-9.542-7z"/></svg>
                        </button>
                        <button type="button" onclick="copyText('{pass_esc}', 'Contraseña copiada')" title="Copiar contraseña"
                                class="text-slate-500 hover:text-indigo-400 p-0.5 transition">
                            <svg class="w-3.5 h-3.5" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M8 16H6a2 2 0 01-2-2V6a2 2 0 012-2h8a2 2 0 012 2v2m-6 12h8a2 2 0 002-2v-8a2 2 0 00-2-2h-8a2 2 0 00-2 2v8a2 2 0 002 2z"/></svg>
                        </button>
                    </div>
                </td>
                <td class="py-3.5 px-5">
                    <div class="inline-flex items-center gap-2 px-2.5 py-1 rounded-full border text-xs font-medium {status_pill_cls}">
                        {status_dot}
                        <span>{status_text}</span>
                        <span class="text-[11px] opacity-70 font-mono">({item['contacts']} SIP · {item['push_count']} Push)</span>
                    </div>
                </td>
                <td class="py-3.5 px-5 text-right">{actions_html}</td>
            </tr>
            """

        alert_html = ""
        if msg:
            alert_html = f"""
            <div class="mb-6 flex items-center gap-3 px-4 py-3 rounded-xl bg-emerald-500/10 border border-emerald-500/30 text-emerald-300 text-sm">
                <svg class="w-5 h-5 shrink-0 text-emerald-400" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"/></svg>
                <span>{html.escape(msg)}</span>
            </div>"""
        elif err:
            alert_html = f"""
            <div class="mb-6 flex items-center gap-3 px-4 py-3 rounded-xl bg-rose-500/10 border border-rose-500/30 text-rose-300 text-sm">
                <svg class="w-5 h-5 shrink-0 text-rose-400" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M12 8v4m0 4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"/></svg>
                <span>{html.escape(err)}</span>
            </div>"""

        door_badge_cls = (
            "bg-emerald-500/15 text-emerald-300 border-emerald-500/30"
            if door_online
            else "bg-amber-500/15 text-amber-300 border-amber-500/30"
        )
        door_badge_txt = "Conectado (SIP 8000)" if door_online else "Sin registro SIP"

        template = """<!DOCTYPE html>
<html lang="es" class="dark">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>PorteroCloud • Consola de Control de Acceso</title>
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    <link href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;500;600&family=Plus+Jakarta+Sans:wght@400;500;600;700;800&display=swap" rel="stylesheet">
    <script src="https://cdn.tailwindcss.com"></script>
    <script src="https://cdnjs.cloudflare.com/ajax/libs/qrcodejs/1.0.0/qrcode.min.js"></script>
    <script>
        tailwind.config = {
            theme: {
                extend: {
                    fontFamily: {
                        sans: ['Plus Jakarta Sans', 'system-ui', 'sans-serif'],
                        mono: ['JetBrains Mono', 'monospace'],
                    }
                }
            }
        }
    </script>
    <style>
        body {
            background-color: #060911;
            background-image:
                radial-gradient(ellipse 65% 45% at 15% -10%, rgba(99, 102, 241, 0.14), transparent),
                radial-gradient(ellipse 50% 40% at 90% 0%, rgba(16, 185, 129, 0.08), transparent);
        }
        .glass-card {
            background: rgba(13, 19, 33, 0.78);
            backdrop-filter: blur(18px);
            -webkit-backdrop-filter: blur(18px);
            border: 1px solid rgba(255, 255, 255, 0.07);
        }
        .nav-active {
            background: linear-gradient(90deg, rgba(99, 102, 241, 0.18), rgba(6, 182, 212, 0.06));
            border: 1px solid rgba(99, 102, 241, 0.35);
            color: #ffffff;
        }
    </style>
</head>
<body class="text-slate-100 min-h-screen font-sans antialiased">
    <div class="min-h-screen flex flex-col lg:flex-row">
        <!-- Sidebar Navegación -->
        <aside class="lg:w-72 shrink-0 border-b lg:border-b-0 lg:border-r border-white/[0.07] bg-[#080C16]/90 px-5 py-6 flex flex-col justify-between">
            <div>
                <!-- Brand Emblem -->
                <div class="flex items-center gap-3 px-2 mb-8">
                    <div class="w-10 h-10 rounded-xl bg-gradient-to-br from-indigo-500 via-indigo-600 to-cyan-500 p-[1px] shadow-lg shadow-indigo-950/60">
                        <div class="w-full h-full rounded-[11px] bg-[#0B1120] flex items-center justify-center">
                            <svg class="w-5 h-5 text-cyan-400" fill="none" stroke="currentColor" stroke-width="1.9" viewBox="0 0 24 24">
                                <rect x="6" y="2.5" width="12" height="19" rx="3.5"/>
                                <circle cx="12" cy="9.5" r="2.75" class="text-indigo-400"/>
                                <rect x="9.5" y="15.5" width="5" height="2.5" rx="1.25" class="text-emerald-400" stroke="currentColor"/>
                            </svg>
                        </div>
                    </div>
                    <div>
                        <div class="text-base font-extrabold tracking-tight text-white leading-tight">PorteroCloud</div>
                        <div class="text-[11px] font-medium text-slate-400">Control de Acceso IP</div>
                    </div>
                </div>

                <!-- Navigation Menu -->
                <div class="text-[10px] font-bold uppercase tracking-widest text-slate-500 px-3 mb-2">Consola</div>
                <nav class="space-y-1.5">
                    <button type="button" onclick="switchSection('units')" id="nav-units"
                            class="nav-active w-full flex items-center gap-3 px-3.5 py-2.5 rounded-xl text-sm font-semibold transition">
                        <svg class="w-4 h-4 text-indigo-400" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M19 21V5a2 2 0 00-2-2H7a2 2 0 00-2 2v16m14 0h2m-2 0h-5m-9 0H3m2 0h5M9 7h1m-1 4h1m4-4h1m-1 4h1m-5 10v-5a1 1 0 011-1h2a1 1 0 011 1v5m-4 0h4"/></svg>
                        <span>Departamentos</span>
                    </button>
                    <button type="button" onclick="switchSection('hardware')" id="nav-hardware"
                            class="w-full flex items-center gap-3 px-3.5 py-2.5 rounded-xl text-sm font-medium text-slate-400 hover:text-slate-100 hover:bg-white/[0.04] border border-transparent transition">
                        <svg class="w-4 h-4 text-cyan-400" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M15 10l4.553-2.276A1 1 0 0121 8.618v6.764a1 1 0 01-1.447.894L15 14M5 18h8a2 2 0 002-2V8a2 2 0 00-2-2H5a2 2 0 00-2 2v8a2 2 0 002 2z"/></svg>
                        <span>Frente KD9203 y Biometría</span>
                    </button>
                    <button type="button" onclick="switchSection('mobile')" id="nav-mobile"
                            class="w-full flex items-center gap-3 px-3.5 py-2.5 rounded-xl text-sm font-medium text-slate-400 hover:text-slate-100 hover:bg-white/[0.04] border border-transparent transition">
                        <svg class="w-4 h-4 text-emerald-400" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M12 18h.01M8 21h8a2 2 0 002-2V5a2 2 0 00-2-2H8a2 2 0 00-2 2v14a2 2 0 002 2z"/></svg>
                        <span>App Android (APK v1.1)</span>
                    </button>
                </nav>
            </div>

            <!-- Server Telemetry Card -->
            <div class="hidden lg:block mt-8 p-4 rounded-2xl bg-[#0D1321] border border-white/[0.07]">
                <div class="flex items-center justify-between mb-2.5">
                    <span class="text-[11px] font-semibold uppercase tracking-wider text-slate-400">Central SIP VPS</span>
                    <span class="inline-flex items-center gap-1.5 text-[11px] font-semibold text-emerald-400">
                        <span class="w-1.5 h-1.5 rounded-full bg-emerald-400 animate-pulse"></span>
                        Operativo
                    </span>
                </div>
                <div class="space-y-1.5 text-xs font-mono">
                    <div class="flex justify-between text-slate-400">
                        <span>Host IP</span>
                        <span class="text-slate-200">__PUB_IP__</span>
                    </div>
                    <div class="flex justify-between text-slate-400">
                        <span>Puerto SIP</span>
                        <span class="text-slate-200">5060 UDP/TCP</span>
                    </div>
                    <div class="flex justify-between text-slate-400">
                        <span>WebRTC WSS</span>
                        <span class="text-indigo-300">Activo :443</span>
                    </div>
                </div>
            </div>
        </aside>

        <!-- Main Workspace -->
        <main class="flex-1 min-w-0 p-5 sm:p-8 lg:p-10 max-w-7xl mx-auto w-full">
            <!-- Top Header -->
            <header class="flex flex-col sm:flex-row sm:items-center justify-between gap-4 mb-8">
                <div>
                    <div class="flex items-center gap-2 text-xs font-medium text-slate-400 mb-1">
                        <span>Administración</span>
                        <span>/</span>
                        <span id="breadcrumbCurrent" class="text-indigo-400">Departamentos y Provisionamiento</span>
                    </div>
                    <h1 id="pageTitle" class="text-2xl sm:text-3xl font-extrabold tracking-tight text-white">Panel del Edificio</h1>
                </div>
                <div class="flex items-center gap-2.5">
                    <a href="/admin"
                       class="inline-flex items-center gap-2 px-3.5 py-2 rounded-xl bg-white/[0.04] hover:bg-white/[0.08] border border-white/10 text-xs font-semibold text-slate-200 transition">
                        <svg class="w-3.5 h-3.5" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15"/></svg>
                        Sincronizar
                    </a>
                    <button type="button" onclick="openAddModal()"
                            class="inline-flex items-center gap-2 px-4 py-2 rounded-xl bg-indigo-600 hover:bg-indigo-500 text-xs font-bold text-white shadow-lg shadow-indigo-950/60 transition">
                        <svg class="w-4 h-4" fill="none" stroke="currentColor" stroke-width="2.2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M12 4v16m8-8H4"/></svg>
                        Nuevo Departamento
                    </button>
                </div>
            </header>

            __ALERT_HTML__

            <!-- SECCIÓN 1: DEPARTAMENTOS -->
            <section id="section-units" class="space-y-6">
                <!-- KPI Grid -->
                <div class="grid grid-cols-1 sm:grid-cols-2 xl:grid-cols-4 gap-4">
                    <div class="glass-card rounded-2xl p-5">
                        <div class="flex items-center justify-between mb-3">
                            <span class="text-xs font-semibold text-slate-400">Departamentos</span>
                            <div class="w-8 h-8 rounded-lg bg-indigo-500/15 border border-indigo-500/25 flex items-center justify-center text-indigo-400">
                                <svg class="w-4 h-4" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M3 12l2-2m0 0l7-7 7 7M5 10v10a1 1 0 001 1h3m10-11l2 2m-2-2v10a1 1 0 01-1 1h-3m-6 0a1 1 0 001-1v-4a1 1 0 011-1h2a1 1 0 011 1v4a1 1 0 001 1m-6 0h6"/></svg>
                            </div>
                        </div>
                        <div class="text-2xl font-extrabold text-white">__TOTAL_UNITS__ <span class="text-xs font-medium text-slate-400">unidades</span></div>
                        <div class="text-xs text-slate-500 mt-1">__ONLINE_UNITS__ en línea actualmente</div>
                    </div>

                    <div class="glass-card rounded-2xl p-5">
                        <div class="flex items-center justify-between mb-3">
                            <span class="text-xs font-semibold text-slate-400">Dispositivos Activos</span>
                            <div class="w-8 h-8 rounded-lg bg-emerald-500/15 border border-emerald-500/25 flex items-center justify-center text-emerald-400">
                                <svg class="w-4 h-4" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M8.111 16.404a5.5 5.5 0 017.778 0M12 20h.01m-7.08-7.071c3.904-3.905 10.236-3.905 14.141 0M1.394 9.393c5.857-5.857 15.355-5.857 21.213 0"/></svg>
                            </div>
                        </div>
                        <div class="text-2xl font-extrabold text-white">__TOTAL_CONTACTS__ <span class="text-xs font-medium text-slate-400">SIP</span></div>
                        <div class="text-xs text-slate-500 mt-1">__TOTAL_PUSH__ tokens Push registrados</div>
                    </div>

                    <div class="glass-card rounded-2xl p-5">
                        <div class="flex items-center justify-between mb-3">
                            <span class="text-xs font-semibold text-slate-400">Frente KD9203</span>
                            <div class="w-8 h-8 rounded-lg bg-cyan-500/15 border border-cyan-500/25 flex items-center justify-center text-cyan-400">
                                <svg class="w-4 h-4" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M15 10l4.553-2.276A1 1 0 0121 8.618v6.764a1 1 0 01-1.447.894L15 14M5 18h8a2 2 0 002-2V8a2 2 0 00-2-2H5a2 2 0 00-2 2v8a2 2 0 002 2z"/></svg>
                            </div>
                        </div>
                        <div class="mt-1">
                            <span class="inline-flex items-center gap-1.5 px-2.5 py-1 rounded-lg border text-xs font-semibold __DOOR_BADGE_CLS__">
                                __DOOR_BADGE_TXT__
                            </span>
                        </div>
                        <div class="text-xs text-slate-500 mt-2">Video H.264 · Keyframe 500ms</div>
                    </div>

                    <div class="glass-card rounded-2xl p-5">
                        <div class="flex items-center justify-between mb-3">
                            <span class="text-xs font-semibold text-slate-400">Llamada y Relé</span>
                            <div class="w-8 h-8 rounded-lg bg-violet-500/15 border border-violet-500/25 flex items-center justify-center text-violet-400">
                                <svg class="w-4 h-4" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M15 7a2 2 0 012 2m4 0a6 6 0 01-7.743 5.743L11 17H9v2H7v2H4a1 1 0 01-1-1v-2.586a1 1 0 01.293-.707l5.964-5.964A6 6 0 1121 9z"/></svg>
                            </div>
                        </div>
                        <div class="text-2xl font-extrabold text-white">300s <span class="text-xs font-medium text-slate-400">máx</span></div>
                        <div class="text-xs text-slate-500 mt-1">Apertura remota vía DTMF <span class="font-mono text-emerald-400">#</span></div>
                    </div>
                </div>

                <!-- Table Card -->
                <div class="glass-card rounded-2xl overflow-hidden shadow-2xl shadow-black/40">
                    <div class="px-5 py-4 border-b border-white/[0.07] flex flex-col sm:flex-row sm:items-center justify-between gap-3">
                        <div>
                            <h2 class="text-sm font-bold text-white">Directorio de Unidades</h2>
                            <p class="text-xs text-slate-400">Gestiona credenciales SIP, enlaces WebApp y códigos QR por departamento.</p>
                        </div>
                        <div class="flex flex-wrap items-center gap-2">
                            <div class="relative">
                                <svg class="w-4 h-4 text-slate-500 absolute left-3 top-1/2 -translate-y-1/2" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z"/></svg>
                                <input id="unitSearch" type="text" oninput="filterTable()" placeholder="Buscar unidad..."
                                       class="bg-[#070B14] border border-white/10 rounded-xl pl-9 pr-3 py-1.5 text-xs text-white placeholder-slate-500 focus:outline-none focus:border-indigo-500 w-44 sm:w-56">
                            </div>
                        </div>
                    </div>

                    <div class="overflow-x-auto">
                        <table class="w-full text-left border-collapse">
                            <thead>
                                <tr class="border-b border-white/[0.07] bg-white/[0.02] text-[11px] font-semibold uppercase tracking-wider text-slate-400">
                                    <th class="py-3 px-5">Unidad / Extensión</th>
                                    <th class="py-3 px-5">Clave SIP</th>
                                    <th class="py-3 px-5">Estado Asterisk</th>
                                    <th class="py-3 px-5 text-right">Provisionamiento y Acceso</th>
                                </tr>
                            </thead>
                            <tbody class="divide-y divide-white/[0.04]">
                                __ROWS_HTML__
                            </tbody>
                        </table>
                    </div>
                </div>
            </section>

            <!-- SECCIÓN 2: FRENTE KD9203 Y BIOMETRÍA -->
            <section id="section-hardware" class="hidden space-y-5">
                <div class="grid grid-cols-1 md:grid-cols-2 gap-5">
                    <div class="glass-card rounded-2xl p-6 space-y-4">
                        <div class="flex items-center justify-between">
                            <div class="flex items-center gap-3">
                                <div class="w-10 h-10 rounded-xl bg-cyan-500/15 border border-cyan-500/30 flex items-center justify-center text-cyan-400">
                                    <svg class="w-5 h-5" fill="none" stroke="currentColor" stroke-width="1.9" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M15 10l4.553-2.276A1 1 0 0121 8.618v6.764a1 1 0 01-1.447.894L15 14M5 18h8a2 2 0 002-2V8a2 2 0 00-2-2H5a2 2 0 00-2 2v8a2 2 0 002 2z"/></svg>
                                </div>
                                <div>
                                    <h3 class="text-base font-bold text-white">Hikvision DS-KD9203-ME6</h3>
                                    <p class="text-xs text-slate-400">Frente Exterior SIP + Cámara Dual</p>
                                </div>
                            </div>
                            <span class="px-2.5 py-1 rounded-lg border text-xs font-semibold __DOOR_BADGE_CLS__">__DOOR_BADGE_TXT__</span>
                        </div>
                        <div class="bg-[#070B14] rounded-xl p-4 border border-white/[0.06] space-y-2 text-xs font-mono">
                            <div class="flex justify-between"><span class="text-slate-500">IP Local LAN</span><span class="text-slate-200">192.168.100.186</span></div>
                            <div class="flex justify-between"><span class="text-slate-500">Usuario SIP</span><span class="text-indigo-300">8000</span></div>
                            <div class="flex justify-between"><span class="text-slate-500">Codec Video</span><span class="text-slate-200">H.264 (Keyframe 500ms)</span></div>
                            <div class="flex justify-between"><span class="text-slate-500">Tiempo Conversación</span><span class="text-emerald-400">300s (5 min)</span></div>
                            <div class="flex justify-between"><span class="text-slate-500">Capacidad Directorio</span><span class="text-slate-200">Hasta 2.000 deptos</span></div>
                        </div>
                        <a href="http://192.168.100.186" target="_blank"
                           class="inline-flex items-center justify-center gap-2 w-full py-2.5 rounded-xl bg-white/[0.06] hover:bg-white/[0.1] border border-white/10 text-xs font-semibold text-white transition">
                            Abrir Panel Web del Equipo (Red Local)
                        </a>
                    </div>

                    <div class="glass-card rounded-2xl p-6 space-y-4">
                        <div class="flex items-center justify-between">
                            <div class="flex items-center gap-3">
                                <div class="w-10 h-10 rounded-xl bg-violet-500/15 border border-violet-500/30 flex items-center justify-center text-violet-400">
                                    <svg class="w-5 h-5" fill="none" stroke="currentColor" stroke-width="1.9" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M5.121 17.804A13.937 13.937 0 0112 16c2.5 0 4.847.655 6.879 1.804M15 10a3 3 0 11-6 0 3 3 0 016 0zm6 2a9 9 0 11-18 0 9 9 0 0118 0z"/></svg>
                                </div>
                                <div>
                                    <h3 class="text-base font-bold text-white">Reconocimiento Facial y Tarjetas</h3>
                                    <p class="text-xs text-slate-400">Biometría Deep Learning Anti-Spoofing</p>
                                </div>
                            </div>
                            <span class="px-2.5 py-1 rounded-lg bg-emerald-500/10 border border-emerald-500/25 text-emerald-300 text-xs font-semibold">Hardware Listo</span>
                        </div>
                        <ul class="space-y-2.5 text-xs text-slate-300">
                            <li class="flex items-start gap-2.5">
                                <span class="w-1.5 h-1.5 rounded-full bg-cyan-400 mt-1.5 shrink-0"></span>
                                <span><strong>Hasta 10.000 rostros</strong> almacenados localmente en el terminal con reconocimiento en menos de 0.2s.</span>
                            </li>
                            <li class="flex items-start gap-2.5">
                                <span class="w-1.5 h-1.5 rounded-full bg-cyan-400 mt-1.5 shrink-0"></span>
                                <span><strong>Lector Mifare 13.56MHz + NFC + Códigos QR</strong> integrado para invitados, personal de mantenimiento y llaveros.</span>
                            </li>
                            <li class="flex items-start gap-2.5">
                                <span class="w-1.5 h-1.5 rounded-full bg-cyan-400 mt-1.5 shrink-0"></span>
                                <span>Para enrolar rostros o tarjetas, ingresa a la IP local del equipo (<span class="font-mono text-slate-200">192.168.100.186</span>) o usa Hikvision iVMS-4200.</span>
                            </li>
                        </ul>
                    </div>
                </div>
            </section>

            <!-- SECCIÓN 3: APP ANDROID Y DESCARGAS -->
            <section id="section-mobile" class="hidden space-y-5">
                <div class="glass-card rounded-2xl p-6 flex flex-col md:flex-row items-center gap-8">
                    <div class="bg-white p-4 rounded-2xl shrink-0 shadow-xl" id="apkQrContainer"></div>
                    <div class="space-y-3 flex-1">
                        <span class="inline-flex items-center px-2.5 py-1 rounded-lg bg-emerald-500/15 border border-emerald-500/30 text-emerald-300 text-xs font-semibold">
                            Versión v1.1 • Android APK
                        </span>
                        <h3 class="text-xl font-extrabold text-white">App Oficial Portero IP</h3>
                        <p class="text-sm text-slate-300 leading-relaxed">
                            Aplicación dedicada para los vecinos con video H.264, apertura directa con botón de puerta, teclado DTMF, historial de llamadas y vinculación rápida por QR.
                        </p>
                        <div class="flex flex-wrap gap-3 pt-2">
                            <a href="https://github.com/navaliente/portero-ip-vps/releases/download/v1.0.0/portero-ip-edificio.apk" target="_blank"
                               class="inline-flex items-center gap-2 px-5 py-2.5 rounded-xl bg-indigo-600 hover:bg-indigo-500 text-white text-xs font-bold shadow-lg transition">
                                <svg class="w-4 h-4" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M4 16v1a3 3 0 003 3h10a3 3 0 003-3v-1m-4-4l-4 4m0 0l-4-4m4 4V4"/></svg>
                                Descargar APK (GitHub Releases)
                            </a>
                            <button type="button" onclick="copyText('https://github.com/navaliente/portero-ip-vps/releases/download/v1.0.0/portero-ip-edificio.apk', 'Enlace APK copiado')"
                                    class="inline-flex items-center gap-2 px-4 py-2.5 rounded-xl bg-white/[0.06] hover:bg-white/[0.1] border border-white/10 text-xs font-semibold text-slate-200 transition">
                                Copiar enlace de descarga
                            </button>
                        </div>
                    </div>
                </div>
            </section>
        </main>
    </div>

    <!-- Modal: Agregar Departamento -->
    <div id="addModal" class="fixed inset-0 bg-black/75 backdrop-blur-sm hidden items-center justify-center p-4 z-50">
        <div class="glass-card rounded-2xl max-w-md w-full p-6 shadow-2xl">
            <div class="flex items-center justify-between mb-4">
                <h3 class="text-lg font-bold text-white">Nuevo Departamento</h3>
                <button type="button" onclick="closeAddModal()" class="text-slate-400 hover:text-white p-1">
                    <svg class="w-5 h-5" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M6 18L18 6M6 6l12 12"/></svg>
                </button>
            </div>
            <form method="POST" action="/admin/add" class="space-y-4">
                <div>
                    <label class="block text-xs font-semibold text-slate-300 mb-1.5">Número de Departamento (100 - 799)</label>
                    <input type="text" name="exten" placeholder="Ej: 304" required pattern="[1-7][0-9]{2}"
                           class="w-full bg-[#070B14] border border-white/15 rounded-xl px-3.5 py-2.5 text-sm text-white focus:outline-none focus:border-indigo-500 font-mono">
                </div>
                <div>
                    <label class="block text-xs font-semibold text-slate-300 mb-1.5">Contraseña SIP (opcional)</label>
                    <input type="text" name="password" placeholder="Dejar vacío para generar clave segura automática"
                           class="w-full bg-[#070B14] border border-white/15 rounded-xl px-3.5 py-2.5 text-sm text-white focus:outline-none focus:border-indigo-500 font-mono">
                </div>
                <div class="flex gap-2.5 pt-2">
                    <button type="button" onclick="closeAddModal()"
                            class="flex-1 py-2.5 rounded-xl bg-white/[0.06] hover:bg-white/[0.1] text-slate-200 text-xs font-semibold">
                        Cancelar
                    </button>
                    <button type="submit"
                            class="flex-1 py-2.5 rounded-xl bg-indigo-600 hover:bg-indigo-500 text-white text-xs font-bold shadow-lg">
                        Crear y Aplicar en Asterisk
                    </button>
                </div>
            </form>
        </div>
    </div>

    <!-- Modal: Código QR -->
    <div id="qrModal" class="fixed inset-0 bg-black/75 backdrop-blur-sm hidden items-center justify-center p-4 z-50">
        <div class="glass-card rounded-2xl max-w-md w-full p-6 text-center shadow-2xl">
            <div class="flex items-center justify-between mb-3">
                <h3 id="qrTitle" class="text-lg font-bold text-white">Vinculación QR</h3>
                <button type="button" onclick="closeQR()" class="text-slate-400 hover:text-white p-1">
                    <svg class="w-5 h-5" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M6 18L18 6M6 6l12 12"/></svg>
                </button>
            </div>
            <div class="grid grid-cols-2 gap-1.5 bg-[#070B14] p-1 rounded-xl border border-white/10 mb-4">
                <button type="button" id="btnTabApp" onclick="switchQRMode('app')" class="py-1.5 text-xs rounded-lg bg-indigo-600 text-white font-semibold">
                    App Portero IP
                </button>
                <button type="button" id="btnTabLinphone" onclick="switchQRMode('linphone')" class="py-1.5 text-xs rounded-lg text-slate-400 font-semibold">
                    Linphone (XML)
                </button>
            </div>
            <p id="qrHelp" class="text-xs text-slate-400 mb-4">
                Escanea este código desde la aplicación móvil.
            </p>
            <div id="qrcode" class="bg-white p-4 rounded-2xl inline-block mx-auto mb-4 shadow-lg"></div>
            <div class="text-left bg-[#070B14] p-3.5 rounded-xl border border-white/[0.08] text-xs font-mono mb-4 space-y-2">
                <div class="flex items-center justify-between gap-2">
                    <span class="text-slate-500">URL de Provisión</span>
                    <button type="button" onclick="copyText(document.getElementById('qrUrl').innerText, 'URL QR copiada')" class="text-indigo-400 hover:underline font-sans font-semibold">Copiar</button>
                </div>
                <div id="qrUrl" class="text-indigo-300 break-all text-[11px]"></div>
            </div>
            <button type="button" onclick="closeQR()" class="w-full py-2.5 bg-white/[0.08] hover:bg-white/[0.12] text-white rounded-xl font-semibold text-xs transition">
                Listo
            </button>
        </div>
    </div>

    <!-- Toast Notification -->
    <div id="toast" class="fixed bottom-5 right-5 bg-emerald-600 text-white text-xs font-semibold px-4 py-2.5 rounded-xl shadow-2xl hidden z-50"></div>

    <script>
        let currentLinphoneUrl = '';
        let currentAppUrl = '';
        let apkQrGenerated = false;

        function showToast(msg) {
            const el = document.getElementById('toast');
            el.innerText = msg;
            el.classList.remove('hidden');
            setTimeout(() => el.classList.add('hidden'), 2200);
        }

        function copyText(txt, toastMsg) {
            if (navigator.clipboard) {
                navigator.clipboard.writeText(txt).then(() => showToast(toastMsg || 'Copiado'));
            }
        }

        function toggleRowPw(btn) {
            const span = btn.parentElement.querySelector('.pw-text');
            const isVis = span.dataset.visible === '1';
            span.innerText = isVis ? '••••••••••••' : span.dataset.pw;
            span.dataset.visible = isVis ? '0' : '1';
        }

        function filterTable() {
            const q = (document.getElementById('unitSearch').value || '').trim().toLowerCase();
            document.querySelectorAll('.unit-row').forEach(row => {
                const hay = row.dataset.search || '';
                row.classList.toggle('hidden', q && !hay.includes(q));
            });
        }

        function switchSection(sec) {
            ['units', 'hardware', 'mobile'].forEach(name => {
                document.getElementById('section-' + name).classList.toggle('hidden', name !== sec);
                const nav = document.getElementById('nav-' + name);
                if (name === sec) {
                    nav.className = 'nav-active w-full flex items-center gap-3 px-3.5 py-2.5 rounded-xl text-sm font-semibold transition';
                } else {
                    nav.className = 'w-full flex items-center gap-3 px-3.5 py-2.5 rounded-xl text-sm font-medium text-slate-400 hover:text-slate-100 hover:bg-white/[0.04] border border-transparent transition';
                }
            });
            const titles = {
                units: ['Panel del Edificio', 'Departamentos y Provisionamiento'],
                hardware: ['Frente KD9203 y Biometría', 'Hardware Exterior & Reconocimiento Facial'],
                mobile: ['App Móvil Oficial v1.1', 'Descarga e Instalación Android']
            };
            document.getElementById('pageTitle').innerText = titles[sec][0];
            document.getElementById('breadcrumbCurrent').innerText = titles[sec][1];
            if (sec === 'mobile' && !apkQrGenerated) {
                apkQrGenerated = true;
                new QRCode(document.getElementById('apkQrContainer'), {
                    text: 'https://github.com/navaliente/portero-ip-vps/releases/download/v1.0.0/portero-ip-edificio.apk',
                    width: 170,
                    height: 170
                });
            }
        }

        function openAddModal() {
            const m = document.getElementById('addModal');
            m.classList.remove('hidden');
            m.classList.add('flex');
        }
        function closeAddModal() {
            const m = document.getElementById('addModal');
            m.classList.add('hidden');
            m.classList.remove('flex');
        }

        function openQR(exten, linphoneUrl, appUrl) {
            currentLinphoneUrl = linphoneUrl;
            currentAppUrl = appUrl;
            document.getElementById('qrTitle').innerText = 'Departamento ' + exten;
            switchQRMode('app');
            const modal = document.getElementById('qrModal');
            modal.classList.remove('hidden');
            modal.classList.add('flex');
        }

        function switchQRMode(mode) {
            const url = (mode === 'app') ? currentAppUrl : currentLinphoneUrl;
            document.getElementById('qrUrl').innerText = url;
            document.getElementById('btnTabApp').className = (mode === 'app')
                ? 'py-1.5 text-xs rounded-lg bg-indigo-600 text-white font-semibold'
                : 'py-1.5 text-xs rounded-lg text-slate-400 font-semibold';
            document.getElementById('btnTabLinphone').className = (mode === 'linphone')
                ? 'py-1.5 text-xs rounded-lg bg-indigo-600 text-white font-semibold'
                : 'py-1.5 text-xs rounded-lg text-slate-400 font-semibold';
            document.getElementById('qrHelp').innerHTML = (mode === 'app')
                ? 'En la <b>App Portero IP</b> selecciona <b>Vincular QR</b>.'
                : 'En <b>Linphone</b> ve a Asistente &rarr; <b>Obtener configuración remota</b>.';
            const container = document.getElementById('qrcode');
            container.innerHTML = '';
            new QRCode(container, { text: url, width: 210, height: 210 });
        }

        function closeQR() {
            const modal = document.getElementById('qrModal');
            modal.classList.add('hidden');
            modal.classList.remove('flex');
        }
    </script>
</body>
</html>"""

        page = (
            template
            .replace("__PUB_IP__", html.escape(pub_ip))
            .replace("__ALERT_HTML__", alert_html)
            .replace("__TOTAL_UNITS__", str(total_units))
            .replace("__ONLINE_UNITS__", str(online_units))
            .replace("__TOTAL_CONTACTS__", str(total_contacts))
            .replace("__TOTAL_PUSH__", str(total_push))
            .replace("__DOOR_BADGE_CLS__", door_badge_cls)
            .replace("__DOOR_BADGE_TXT__", door_badge_txt)
            .replace("__ROWS_HTML__", rows_html)
        )
        body = page.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def render_neighbor_app(self, exten: str, token: str) -> None:
        pub_ip = get_public_ip()
        sip_pass = ""
        for item in parse_extensions():
            if item["exten"] == exten:
                sip_pass = item["password"]
                break
        page = f"""<!DOCTYPE html>
<html lang="es" class="dark">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
    <title>PorteroCloud • Depto {html.escape(exten)}</title>
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    <link href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;600&family=Plus+Jakarta+Sans:wght@400;500;600;700;800&display=swap" rel="stylesheet">
    <script src="https://cdn.tailwindcss.com"></script>
    <script src="https://cdn.jsdelivr.net/npm/jssip@3.10.0/dist/jssip.min.js"></script>
    <script>
        tailwind.config = {{
            theme: {{
                extend: {{
                    fontFamily: {{
                        sans: ['Plus Jakarta Sans', 'system-ui', 'sans-serif'],
                        mono: ['JetBrains Mono', 'monospace'],
                    }}
                }}
            }}
        }}
    </script>
</head>
<body class="bg-[#060911] text-white min-h-screen flex items-center justify-center p-2 sm:p-6 font-sans antialiased">
    <div class="w-full max-w-md bg-[#0D1321] border border-white/10 rounded-[2rem] overflow-hidden shadow-[0_24px_70px_rgba(0,0,0,0.75)] flex flex-col min-h-[700px]">
        <!-- Top Bar -->
        <div class="bg-[#0B1120] px-5 py-4 flex items-center justify-between border-b border-white/[0.07]">
            <div class="flex items-center gap-3">
                <div class="w-9 h-9 rounded-xl bg-gradient-to-br from-indigo-500 to-cyan-500 p-[1px]">
                    <div class="w-full h-full rounded-[11px] bg-[#0B1120] flex items-center justify-center">
                        <svg class="w-4 h-4 text-cyan-400" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24">
                            <rect x="6" y="2.5" width="12" height="19" rx="3.5"/>
                            <circle cx="12" cy="9.5" r="2.75"/>
                            <rect x="9.5" y="15.5" width="5" height="2.5" rx="1.25"/>
                        </svg>
                    </div>
                </div>
                <div>
                    <div class="font-bold text-sm text-white leading-tight">Departamento {html.escape(exten)}</div>
                    <div class="text-[11px] text-slate-400">Frente KD9203 · Ext. 8000</div>
                </div>
            </div>
            <span id="webrtcStatusBadge" class="inline-flex items-center gap-1.5 text-[11px] px-2.5 py-1 rounded-full bg-indigo-500/15 text-indigo-300 border border-indigo-500/30 font-mono">
                <span class="w-1.5 h-1.5 rounded-full bg-indigo-400 animate-pulse"></span>
                <span>{html.escape(pub_ip)}</span>
            </span>
        </div>

        <!-- Visor de Video HD -->
        <div class="relative flex-1 bg-[#03060D] m-3 rounded-2xl overflow-hidden border border-white/[0.08] flex flex-col items-center justify-center">
            <video id="remoteVideo" autoplay playsinline class="w-full h-full object-cover hidden"></video>
            <audio id="remoteAudio" autoplay></audio>
            <img id="liveCameraImg" alt="Cámara KD9203" class="w-full h-full object-cover hidden" />

            <!-- Standby -->
            <div id="cameraPlaceholder" class="text-center p-6">
                <div class="w-20 h-20 rounded-2xl bg-[#0D1321] border border-white/10 flex items-center justify-center mx-auto mb-4 shadow-xl">
                    <svg class="w-9 h-9 text-cyan-400" fill="none" stroke="currentColor" stroke-width="1.6" viewBox="0 0 24 24">
                        <path stroke-linecap="round" stroke-linejoin="round" d="M15 10l4.553-2.276A1 1 0 0121 8.618v6.764a1 1 0 01-1.447.894L15 14M5 18h8a2 2 0 002-2V8a2 2 0 00-2-2H5a2 2 0 00-2 2v8a2 2 0 002 2z"/>
                    </svg>
                </div>
                <p id="callStatusTitle" class="text-base font-bold text-white mb-1">En espera de llamado</p>
                <p id="callStatusSub" class="text-xs text-slate-400">
                    Extensión {html.escape(exten)}-webrtc conectada · H.264 Ready
                </p>
            </div>

            <!-- Live Pill -->
            <div id="liveBadge" class="hidden absolute top-3 left-3 bg-black/75 backdrop-blur-md px-3 py-1 rounded-full text-[11px] font-semibold flex items-center gap-2 border border-white/15 z-20">
                <span class="w-2 h-2 rounded-full bg-rose-500 animate-ping"></span>
                <span id="liveBadgeText">KD9203 · H.264 EN VIVO</span>
            </div>

            <!-- Ringing Overlay -->
            <div id="ringingBanner" class="hidden absolute inset-x-3 top-12 bg-[#0F172A]/95 backdrop-blur-xl text-white p-4 rounded-2xl text-center shadow-2xl border border-emerald-500/40 z-20">
                <div class="inline-flex items-center gap-1.5 text-[11px] font-bold uppercase tracking-widest text-emerald-400 mb-1">
                    <span class="w-2 h-2 rounded-full bg-emerald-400 animate-ping"></span>
                    Timbre de Entrada Principal
                </div>
                <p class="text-sm font-bold text-white">Visita llamando al Depto {html.escape(exten)}</p>
                <div class="flex gap-2 justify-center mt-3">
                    <button onclick="answerCall()" class="inline-flex items-center gap-1.5 px-4 py-2 bg-indigo-600 hover:bg-indigo-500 text-white rounded-xl text-xs font-bold shadow">
                        Atender Video
                    </button>
                    <button onclick="sendDtmfUnlock()" class="inline-flex items-center gap-1.5 px-4 py-2 bg-emerald-600 hover:bg-emerald-500 text-white rounded-xl text-xs font-bold shadow">
                        Abrir Puerta (#)
                    </button>
                </div>
            </div>

            <!-- Door Opened Confirmation -->
            <div id="doorOpenedBanner" class="hidden absolute inset-x-5 top-1/2 -translate-y-1/2 bg-emerald-600/95 backdrop-blur-md text-white p-5 rounded-2xl text-center shadow-2xl border border-emerald-300/40 z-30">
                <div class="w-11 h-11 rounded-full bg-white/20 flex items-center justify-center mx-auto mb-2">
                    <svg class="w-6 h-6 text-white" fill="none" stroke="currentColor" stroke-width="2.2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M8 11V7a4 4 0 118 0m-4 8v2m-6 4h12a2 2 0 002-2v-6a2 2 0 00-2-2H6a2 2 0 00-2 2v6a2 2 0 002 2z"/></svg>
                </div>
                <p class="text-lg font-extrabold mb-0.5">Puerta Destrabada</p>
                <p id="doorOpenedSub" class="text-xs text-emerald-100">Pulso DTMF (#) enviado al frente KD9203</p>
            </div>
        </div>

        <!-- Dock Controls -->
        <div class="bg-[#0B1120] p-5 rounded-t-3xl border-t border-white/[0.07] space-y-3">
            <button onclick="sendDtmfUnlock()"
                    class="w-full py-3.5 bg-gradient-to-r from-emerald-600 to-emerald-500 hover:from-emerald-500 hover:to-emerald-400 active:scale-[0.99] text-white font-bold text-sm rounded-2xl shadow-lg shadow-emerald-950/60 flex items-center justify-center gap-2 transition">
                <svg class="w-4 h-4" fill="none" stroke="currentColor" stroke-width="2.2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M15 7a2 2 0 012 2m4 0a6 6 0 01-7.743 5.743L11 17H9v2H7v2H4a1 1 0 01-1-1v-2.586a1 1 0 01.293-.707l5.964-5.964A6 6 0 1121 9z"/></svg>
                <span>Abrir Puerta Principal (#)</span>
            </button>

            <div class="grid grid-cols-2 gap-2.5">
                <button onclick="startMonitor()"
                        class="py-2.5 px-3 bg-indigo-600/90 hover:bg-indigo-500 text-white font-semibold text-xs rounded-xl flex items-center justify-center gap-1.5 transition">
                    <svg class="w-4 h-4" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M15 10l4.553-2.276A1 1 0 0121 8.618v6.764a1 1 0 01-1.447.894L15 14M5 18h8a2 2 0 002-2V8a2 2 0 00-2-2H5a2 2 0 00-2 2v8a2 2 0 002 2z"/></svg>
                    <span>Ver Cámara (8000)</span>
                </button>
                <button onclick="simulateRing()"
                        class="py-2.5 px-3 bg-white/[0.06] hover:bg-white/[0.1] border border-white/10 text-slate-200 font-semibold text-xs rounded-xl flex items-center justify-center gap-1.5 transition">
                    <svg class="w-4 h-4 text-amber-400" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M15 17h5l-1.405-1.405A2.032 2.032 0 0118 14.158V11a6.002 6.002 0 00-4-5.659V5a2 2 0 10-4 0v.341C7.67 6.165 6 8.388 6 11v3.159c0 .538-.214 1.055-.595 1.436L4 17h5m6 0v1a3 3 0 11-6 0v-1m6 0H9"/></svg>
                    <span>Probar Timbre</span>
                </button>
            </div>

            <div class="grid grid-cols-3 gap-2 pt-1">
                <button onclick="answerCall()"
                        class="py-2 bg-emerald-500/15 hover:bg-emerald-500/25 border border-emerald-500/30 text-emerald-300 rounded-xl text-xs font-semibold">
                    Atender
                </button>
                <button onclick="toggleMute()" id="muteBtn"
                        class="py-2 bg-white/[0.05] hover:bg-white/[0.1] border border-white/10 text-slate-200 rounded-xl text-xs font-medium">
                    Mic: Activo
                </button>
                <button onclick="endCall()"
                        class="py-2 bg-rose-500/15 hover:bg-rose-500/25 border border-rose-500/30 text-rose-300 rounded-xl text-xs font-semibold">
                    Colgar
                </button>
            </div>
        </div>
    </div>

    <script>
        let micOn = true;
        let audioCtx = null;
        let ringtoneTimer = null;
        let cameraTimer = null;
        let lastKdCallStatus = 'idle';
        let ua = null;
        let currentSession = null;
        const EXTEN = "{html.escape(exten)}";
        const SIP_PASS = "{html.escape(sip_pass)}";
        const LOCAL_API = "http://localhost:8090";

        function playDingDongOnce() {{
            try {{
                if (!audioCtx) {{
                    const AudioContext = window.AudioContext || window.webkitAudioContext;
                    audioCtx = new AudioContext();
                }}
                if (audioCtx.state === 'suspended') audioCtx.resume();
                const now = audioCtx.currentTime;
                const osc1 = audioCtx.createOscillator();
                const gain1 = audioCtx.createGain();
                osc1.frequency.setValueAtTime(784, now);
                gain1.gain.setValueAtTime(0.45, now);
                gain1.gain.exponentialRampToValueAtTime(0.01, now + 0.45);
                osc1.connect(gain1);
                gain1.connect(audioCtx.destination);
                osc1.start(now);
                osc1.stop(now + 0.45);

                const osc2 = audioCtx.createOscillator();
                const gain2 = audioCtx.createGain();
                osc2.frequency.setValueAtTime(659.25, now + 0.35);
                gain2.gain.setValueAtTime(0.45, now + 0.35);
                gain2.gain.exponentialRampToValueAtTime(0.008, now + 1.1);
                osc2.connect(gain2);
                gain2.connect(audioCtx.destination);
                osc2.start(now + 0.35);
                osc2.stop(now + 1.1);
            }} catch (_) {{}}
        }}

        function startRingingLoop() {{
            playDingDongOnce();
            if (!ringtoneTimer) ringtoneTimer = setInterval(playDingDongOnce, 1800);
        }}

        function stopRingingLoop() {{
            if (ringtoneTimer) {{
                clearInterval(ringtoneTimer);
                ringtoneTimer = null;
            }}
        }}

        function startCameraFeed() {{
            const img = document.getElementById('liveCameraImg');
            document.getElementById('liveBadge').classList.remove('hidden');
            document.getElementById('callStatusTitle').innerText = 'Monitoreando Frente KD9203 (Ext 8000)';
            document.getElementById('callStatusSub').innerText = 'Streaming de Video H.264 + Audio bidireccional activo';

            const refreshFrame = () => {{
                const nextImg = new Image();
                nextImg.onload = () => {{
                    img.src = nextImg.src;
                    img.classList.remove('hidden');
                    document.getElementById('cameraPlaceholder').classList.add('hidden');
                }};
                nextImg.src = LOCAL_API + '/api/snapshot.jpg?t=' + Date.now();
            }};
            refreshFrame();
            if (!cameraTimer) cameraTimer = setInterval(refreshFrame, 350);
        }}

        function startMonitor() {{
            stopRingingLoop();
            startCameraFeed();
            if (ua && (!currentSession || currentSession.isEnded())) {{
                try {{
                    ua.call('sip:8000@138.219.41.163', {{ mediaConstraints: {{ audio: true, video: true }} }});
                }} catch (_) {{}}
            }}
        }}

        function simulateRing() {{
            startRingingLoop();
            startCameraFeed();
            document.getElementById('ringingBanner').classList.remove('hidden');
            document.getElementById('callStatusTitle').innerText = 'Timbre desde Frente KD9203';
            document.getElementById('callStatusSub').innerText = 'Visita en puerta principal -> Presiona Abrir Puerta (#)';
        }}

        async function answerCall() {{
            stopRingingLoop();
            document.getElementById('ringingBanner').classList.add('hidden');
            startCameraFeed();
            if (currentSession && currentSession.isInProgress()) {{
                try {{ currentSession.answer({{ mediaConstraints: {{ audio: true, video: true }} }}); }} catch (_) {{}}
            }}
            try {{
                await fetch(LOCAL_API + '/api/callsignal', {{
                    method: 'POST',
                    headers: {{ 'Content-Type': 'application/json' }},
                    body: JSON.stringify({{ cmdType: 'answer' }})
                }});
            }} catch (_) {{}}
        }}

        async function sendDtmfUnlock() {{
            stopRingingLoop();
            if (currentSession && currentSession.isEstablished()) {{
                try {{ currentSession.sendDTMF('#'); }} catch (_) {{}}
            }}
            const banner = document.getElementById('doorOpenedBanner');
            const sub = document.getElementById('doorOpenedSub');
            banner.classList.remove('hidden');
            try {{
                const res = await fetch(LOCAL_API + '/api/unlock', {{ method: 'POST' }});
                const data = await res.json();
                if (data.ok) sub.innerText = '¡Relé Físico #1 del KD9203 activado en vivo!';
            }} catch (_) {{}}
            setTimeout(() => banner.classList.add('hidden'), 3500);
        }}

        function toggleMute() {{
            micOn = !micOn;
            document.getElementById('muteBtn').innerText = micOn ? 'Mic: Activo' : 'Mic: Silencio';
        }}

        async function endCall() {{
            stopRingingLoop();
            if (cameraTimer) {{ clearInterval(cameraTimer); cameraTimer = null; }}
            document.getElementById('liveCameraImg').classList.add('hidden');
            document.getElementById('remoteVideo').classList.add('hidden');
            document.getElementById('cameraPlaceholder').classList.remove('hidden');
            document.getElementById('liveBadge').classList.add('hidden');
            document.getElementById('ringingBanner').classList.add('hidden');
            document.getElementById('callStatusTitle').innerText = 'En Espera de Timbre';
            document.getElementById('callStatusSub').innerText = 'Extensión ' + EXTEN + '-webrtc lista • Notificaciones Push Activas';
            if (currentSession) {{
                try {{ currentSession.terminate(); }} catch (_) {{}}
                currentSession = null;
            }}
            try {{
                await fetch(LOCAL_API + '/api/callsignal', {{
                    method: 'POST',
                    headers: {{ 'Content-Type': 'application/json' }},
                    body: JSON.stringify({{ cmdType: 'hangUp' }})
                }});
            }} catch (_) {{}}
        }}

        async function pollKdStatus() {{
            try {{
                const res = await fetch(LOCAL_API + '/api/status');
                const data = await res.json();
                if (data.ok) {{
                    if (data.callStatus === 'ring' && lastKdCallStatus !== 'ring') {{
                        simulateRing();
                    }} else if (data.callStatus === 'idle' && lastKdCallStatus !== 'idle') {{
                        stopRingingLoop();
                        document.getElementById('ringingBanner').classList.add('hidden');
                    }}
                    lastKdCallStatus = data.callStatus;
                }}
            }} catch (_) {{}}
        }}

        function initWebRTC() {{
            if (typeof JsSIP === 'undefined' || !SIP_PASS) return;
            try {{
                const socket = new JsSIP.WebSocketInterface('wss://vps-6615824-x.dattaweb.com/ws');
                ua = new JsSIP.UA({{
                    sockets: [socket],
                    uri: 'sip:' + EXTEN + '-webrtc@138.219.41.163',
                    authorization_user: EXTEN,
                    password: SIP_PASS,
                    register: true
                }});
                ua.on('registered', () => {{
                    document.getElementById('webrtcStatusBadge').innerText = 'EN LÍNEA (WSS)';
                }});
                ua.on('newRTCSession', (data) => {{
                    currentSession = data.session;
                    if (currentSession.direction === 'incoming') simulateRing();
                    currentSession.on('peerconnection', (e) => {{
                        e.peerconnection.addEventListener('track', (ev) => {{
                            if (ev.track.kind === 'video') {{
                                const v = document.getElementById('remoteVideo');
                                v.srcObject = ev.streams[0];
                                v.classList.remove('hidden');
                                document.getElementById('cameraPlaceholder').classList.add('hidden');
                            }} else if (ev.track.kind === 'audio') {{
                                document.getElementById('remoteAudio').srcObject = ev.streams[0];
                            }}
                        }});
                    }});
                }});
                ua.start();
            }} catch (_) {{}}
        }}

        initWebRTC();
        setInterval(pollKdStatus, 700);
        pollKdStatus();
    </script>
</body>
</html>"""
        body = page.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    print(f"[OK] Panel Web Portero IP escuchando en http://0.0.0.0:{PORT}/admin")
    server = http.server.ThreadingHTTPServer(("0.0.0.0", PORT), PorteroAdminHandler)
    server.serve_forever()
