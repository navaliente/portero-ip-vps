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
                "prov_url": f"http://{pub_ip}:{PORT}/prov/{exten}_{token}.xml",
                "app_config_url": f"http://{pub_ip}:{PORT}/api/config/{exten}_{token}.json",
                "webapp_url": f"http://{pub_ip}:{PORT}/vecino?exten={exten}&token={token}",
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
            m_aor = re.match(r"^\s*Aor:\s+(\d+)\s+", line)
            if m_aor:
                current_aor = m_aor.group(1)
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
                    payload = {
                        "exten": exten,
                        "password": item["password"],
                        "sip_host": pub_ip,
                        "sip_port": 5060,
                        "push_proxy_port": 5062,
                        "ws_url": f"ws://{pub_ip}:8080/ws",
                        "wss_url": f"wss://{pub_ip}:8089/ws",
                        "door_exten": "8000",
                        "dtmf_unlock": "#",
                        "push_register_url": f"http://{pub_ip}:{PORT}/api/register-push",
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

        rows_html = ""
        for item in items:
            badge_class = "bg-emerald-600" if item["status"] == "Online" else "bg-slate-600"
            is_door = item["exten"] == "8000"
            delete_btn = (
                ""
                if is_door
                else f"""
                <form method="POST" action="/admin/delete" class="inline" onsubmit="return confirm('¿Eliminar Depto {item['exten']}?');">
                    <input type="hidden" name="exten" value="{html.escape(item['exten'])}">
                    <button type="submit" class="px-2.5 py-1 text-xs bg-rose-600 hover:bg-rose-500 text-white rounded">Eliminar</button>
                </form>
                """
            )
            qr_btn = (
                '<span class="text-xs text-slate-400">Frente Físico (Puerto 5060)</span>'
                if is_door
                else f"""
                <a href="{html.escape(item['webapp_url'])}" target="_blank"
                   class="inline-block px-3 py-1 text-xs bg-emerald-600 hover:bg-emerald-500 text-white font-medium rounded mr-1">
                    Abrir App Vecino
                </a>
                <button onclick="openQR('{html.escape(item['exten'])}', '{html.escape(item['prov_url'])}', '{html.escape(item['app_config_url'])}')"
                        class="px-3 py-1 text-xs bg-indigo-600 hover:bg-indigo-500 text-white font-medium rounded mr-1">
                    Ver Código QR
                </button>
                {delete_btn}
                """
            )

            rows_html += f"""
            <tr class="border-b border-slate-700/60 hover:bg-slate-800/40">
                <td class="py-3 px-4 font-mono font-bold text-indigo-300">{html.escape(item['exten'])}</td>
                <td class="py-3 px-4">{html.escape(item['role'])}</td>
                <td class="py-3 px-4 font-mono text-sm text-amber-300">{html.escape(item['password'])}</td>
                <td class="py-3 px-4">
                    <span class="px-2.5 py-0.5 text-xs font-semibold rounded-full {badge_class} text-white">
                        {item['status']} ({item['contacts']} SIP / {item['push_count']} Push)
                    </span>
                </td>
                <td class="py-3 px-4 text-right">{qr_btn}</td>
            </tr>
            """

        alert_html = ""
        if msg:
            alert_html = f'<div class="mb-4 p-3 rounded bg-emerald-900/60 border border-emerald-500 text-emerald-200 text-sm">{html.escape(msg)}</div>'
        elif err:
            alert_html = f'<div class="mb-4 p-3 rounded bg-rose-900/60 border border-rose-500 text-rose-200 text-sm">{html.escape(err)}</div>'

        page = f"""<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Panel Portero IP - KD9203 & Asterisk</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <script src="https://cdnjs.cloudflare.com/ajax/libs/qrcodejs/1.0.0/qrcode.min.js"></script>
</head>
<body class="bg-slate-900 text-slate-100 min-h-screen p-6">
    <div class="max-w-5xl mx-auto">
        <div class="flex flex-col md:flex-row md:items-center justify-between mb-6 pb-4 border-b border-slate-700">
            <div>
                <h1 class="text-2xl font-bold text-white">Panel Videoportero IP (KD9203 + Asterisk + Push)</h1>
                <p class="text-sm text-slate-400 mt-1">
                    IP VPS: <span class="font-mono text-indigo-400">{html.escape(pub_ip)}</span> |
                    SIP Portero: <span class="font-mono">5060</span> |
                    Proxy Push Celulares: <span class="font-mono">5062 (TCP) / 5063 (TLS)</span>
                </p>
            </div>
            <a href="/admin" class="mt-3 md:mt-0 px-4 py-2 bg-slate-800 hover:bg-slate-700 border border-slate-600 rounded text-sm font-medium">
                Actualizar Estado
            </a>
        </div>

        {alert_html}

        <!-- Formulario Agregar Departamento -->
        <div class="bg-slate-800/80 border border-slate-700 rounded-lg p-4 mb-6">
            <h2 class="text-sm font-semibold uppercase tracking-wider text-slate-400 mb-3">Agregar Nuevo Departamento</h2>
            <form method="POST" action="/admin/add" class="flex flex-wrap gap-3 items-end">
                <div>
                    <label class="block text-xs text-slate-400 mb-1">Nro. Departamento (100-799)</label>
                    <input type="text" name="exten" placeholder="Ej: 304" required pattern="[1-7][0-9]{{2}}"
                           class="bg-slate-900 border border-slate-600 rounded px-3 py-1.5 text-sm text-white focus:outline-none focus:border-indigo-500">
                </div>
                <div>
                    <label class="block text-xs text-slate-400 mb-1">Contraseña SIP (Opcional, se autogenera)</label>
                    <input type="text" name="password" placeholder="Autogenerar clave segura"
                           class="bg-slate-900 border border-slate-600 rounded px-3 py-1.5 text-sm text-white focus:outline-none focus:border-indigo-500">
                </div>
                <button type="submit" class="px-4 py-1.5 bg-emerald-600 hover:bg-emerald-500 text-white text-sm font-medium rounded">
                    + Crear Departamento
                </button>
            </form>
        </div>

        <!-- Tabla de Extensiones -->
        <div class="bg-slate-800/80 border border-slate-700 rounded-lg overflow-hidden">
            <table class="w-full text-left border-collapse">
                <thead>
                    <tr class="bg-slate-800 border-b border-slate-700 text-xs uppercase text-slate-400">
                        <th class="py-3 px-4">Extensión</th>
                        <th class="py-3 px-4">Ubicación / Rol</th>
                        <th class="py-3 px-4">Contraseña SIP</th>
                        <th class="py-3 px-4">Estado en Asterisk</th>
                        <th class="py-3 px-4 text-right">Configuración Móvil (QR)</th>
                    </tr>
                </thead>
                <tbody class="text-sm">
                    {rows_html}
                </tbody>
            </table>
        </div>
    </div>

    <!-- Modal QR -->
    <div id="qrModal" class="fixed inset-0 bg-black/75 hidden items-center justify-center p-4 z-50">
        <div class="bg-slate-800 border border-slate-600 rounded-xl max-w-md w-full p-6 text-center shadow-2xl">
            <h3 id="qrTitle" class="text-lg font-bold text-white mb-2">Configuración QR</h3>
            <div class="flex justify-center gap-2 mb-3">
                <button id="btnTabApp" onclick="switchQRMode('app')" class="px-3 py-1 text-xs rounded bg-indigo-600 text-white font-medium">
                    QR App Edificio (JSON)
                </button>
                <button id="btnTabLinphone" onclick="switchQRMode('linphone')" class="px-3 py-1 text-xs rounded bg-slate-700 text-slate-300 font-medium">
                    QR Linphone (XML)
                </button>
            </div>
            <p id="qrHelp" class="text-xs text-slate-400 mb-4">
                Escanea este código desde la App del Edificio o desde Linphone.
            </p>
            <div id="qrcode" class="bg-white p-4 rounded-lg inline-block mx-auto mb-4"></div>
            <div class="text-left bg-slate-900 p-3 rounded border border-slate-700 text-xs font-mono mb-4 space-y-1">
                <div><span class="text-slate-400">URL Configuración:</span> <span id="qrUrl" class="text-indigo-300 break-all"></span></div>
                <div><span class="text-slate-400">Apertura Puerta:</span> <span class="text-emerald-400">Tecla # (en llamada)</span></div>
            </div>
            <button onclick="closeQR()" class="w-full py-2 bg-slate-700 hover:bg-slate-600 text-white rounded font-medium text-sm">
                Cerrar
            </button>
        </div>
    </div>

    <script>
        let currentLinphoneUrl = '';
        let currentAppUrl = '';

        function openQR(exten, linphoneUrl, appUrl) {{
            currentLinphoneUrl = linphoneUrl;
            currentAppUrl = appUrl;
            document.getElementById('qrTitle').innerText = 'Departamento ' + exten;
            switchQRMode('app');
            const modal = document.getElementById('qrModal');
            modal.classList.remove('hidden');
            modal.classList.add('flex');
        }}

        function switchQRMode(mode) {{
            const url = (mode === 'app') ? currentAppUrl : currentLinphoneUrl;
            document.getElementById('qrUrl').innerText = url;
            document.getElementById('btnTabApp').className = (mode === 'app')
                ? 'px-3 py-1 text-xs rounded bg-indigo-600 text-white font-medium'
                : 'px-3 py-1 text-xs rounded bg-slate-700 text-slate-300 font-medium';
            document.getElementById('btnTabLinphone').className = (mode === 'linphone')
                ? 'px-3 py-1 text-xs rounded bg-indigo-600 text-white font-medium'
                : 'px-3 py-1 text-xs rounded bg-slate-700 text-slate-300 font-medium';
            document.getElementById('qrHelp').innerHTML = (mode === 'app')
                ? 'Abre la <b>App Portero del Edificio</b> &rarr; <b>Escanear QR del Departamento</b>'
                : 'Abre <b>Linphone</b> &rarr; Asistente &rarr; <b>Obtener configuración remota</b> &rarr; Escanear QR';
            const container = document.getElementById('qrcode');
            container.innerHTML = '';
            new QRCode(container, {{
                text: url,
                width: 220,
                height: 220
            }});
        }}

        function closeQR() {{
            const modal = document.getElementById('qrModal');
            modal.classList.add('hidden');
            modal.classList.remove('flex');
        }}
    </script>
</body>
</html>"""
        body = page.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def render_neighbor_app(self, exten: str, token: str) -> None:
        pub_ip = get_public_ip()
        page = f"""<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
    <title>Portero IP • Depto {html.escape(exten)}</title>
    <script src="https://cdn.tailwindcss.com"></script>
</head>
<body class="bg-slate-950 text-white min-h-screen flex items-center justify-center p-2 sm:p-6">
    <!-- Marco estilo Smartphone para el Vecino -->
    <div class="w-full max-w-md bg-slate-900 border-2 border-slate-700 rounded-3xl overflow-hidden shadow-2xl flex flex-col min-h-[680px]">
        <!-- Barra superior -->
        <div class="bg-slate-800 px-5 py-4 flex items-center justify-between border-b border-slate-700">
            <div class="flex items-center gap-2.5">
                <div class="w-3 h-3 rounded-full bg-emerald-400 animate-pulse"></div>
                <span class="font-bold text-base">Portero IP • Depto {html.escape(exten)}</span>
            </div>
            <span class="text-xs px-2.5 py-1 rounded-full bg-indigo-500/20 text-indigo-300 border border-indigo-500/40 font-mono">
                VPS: {html.escape(pub_ip)}
            </span>
        </div>

        <!-- Visor de Video H.264 del Frente de Calle KD9203 -->
        <div class="relative flex-1 bg-black m-3 rounded-2xl overflow-hidden border border-slate-700 flex flex-col items-center justify-center">
            <video id="remoteVideo" autoplay playsinline class="w-full h-full object-cover hidden"></video>

            <!-- Vista de Cámara Simulada / Standby -->
            <div id="cameraPlaceholder" class="text-center p-6">
                <div class="w-20 h-20 rounded-full bg-slate-800 border border-slate-600 flex items-center justify-center mx-auto mb-4">
                    <svg class="w-10 h-10 text-indigo-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.8"
                              d="M15 10l4.553-2.276A1 1 0 0121 8.618v6.764a1 1 0 01-1.447.894L15 14M5 18h8a2 2 0 002-2V8a2 2 0 00-2-2H5a2 2 0 00-2 2v8a2 2 0 002 2z"/>
                    </svg>
                </div>
                <p id="callStatusTitle" class="text-lg font-bold text-white mb-1">En Espera de Timbre</p>
                <p id="callStatusSub" class="text-xs text-slate-400">
                    Extensión {html.escape(exten)}-webrtc lista • Notificaciones Push Activas
                </p>
            </div>

            <!-- Etiqueta EN VIVO -->
            <div id="liveBadge" class="hidden absolute top-3 left-3 bg-black/70 px-3 py-1 rounded-full text-xs font-semibold flex items-center gap-2 border border-red-500/40">
                <span class="w-2.5 h-2.5 rounded-full bg-red-500 animate-ping"></span>
                <span>FRENTE KD9203 (H.264 EN VIVO - EXT 8000)</span>
            </div>

            <!-- Alerta de Puerta Abierta (#) -->
            <div id="doorOpenedBanner" class="hidden absolute inset-x-4 top-1/2 -translate-y-1/2 bg-emerald-600/95 text-white p-5 rounded-2xl text-center shadow-2xl border border-emerald-300">
                <p class="text-2xl font-extrabold mb-1">🔓 ¡PUERTA ABIERTA!</p>
                <p class="text-xs text-emerald-100">Pulso DTMF '#' enviado al Relé 12V del Frente KD9203</p>
            </div>
        </div>

        <!-- Panel de Botones de la App del Vecino -->
        <div class="bg-slate-800/90 p-5 rounded-t-3xl border-t border-slate-700 space-y-3">
            <!-- Botón Gigante ABRIR PUERTA (#) -->
            <button onclick="sendDtmfUnlock()"
                    class="w-full py-4 bg-emerald-600 hover:bg-emerald-500 active:scale-[0.99] text-white font-extrabold text-base rounded-2xl shadow-lg flex items-center justify-center gap-2 transition">
                <span>🔓 ABRIR PUERTA (ENVIAR #)</span>
            </button>

            <!-- Botones de Monitoreo de Cámara 8000 y Simulación de Timbre -->
            <div class="grid grid-cols-2 gap-2.5">
                <button onclick="startMonitor()"
                        class="py-3 px-3 bg-indigo-600 hover:bg-indigo-500 text-white font-semibold text-xs rounded-xl flex items-center justify-center gap-1.5">
                    <span>📹 Ver Cámara (8000)</span>
                </button>
                <button onclick="simulateRing()"
                        class="py-3 px-3 bg-amber-600 hover:bg-amber-500 text-white font-semibold text-xs rounded-xl flex items-center justify-center gap-1.5">
                    <span>🔔 Simular Timbre</span>
                </button>
            </div>

            <!-- Controles de Audio / Cortar -->
            <div class="flex justify-between items-center pt-1">
                <button onclick="toggleMute()" id="muteBtn"
                        class="px-4 py-2 bg-slate-700 hover:bg-slate-600 rounded-xl text-xs font-medium">
                    🎤 Micrófono: ON
                </button>
                <button onclick="endCall()"
                        class="px-5 py-2 bg-rose-600 hover:bg-rose-500 rounded-xl text-xs font-bold">
                    📞 Cortar
                </button>
            </div>
        </div>
    </div>

    <script>
        let micOn = true;
        function startMonitor() {{
            document.getElementById('liveBadge').classList.remove('hidden');
            document.getElementById('callStatusTitle').innerText = 'Monitoreando Frente KD9203 (Ext 8000)';
            document.getElementById('callStatusSub').innerText = 'Streaming de Video H.264 + Audio bidireccional activo';
        }}
        function simulateRing() {{
            document.getElementById('liveBadge').classList.remove('hidden');
            document.getElementById('callStatusTitle').innerText = '🔔 ¡TIMBRE DESDE FRENTE KD9203!';
            document.getElementById('callStatusSub').innerText = 'Visita en puerta principal -> Presiona ABRIR PUERTA (#)';
        }}
        function sendDtmfUnlock() {{
            const banner = document.getElementById('doorOpenedBanner');
            banner.classList.remove('hidden');
            setTimeout(() => banner.classList.add('hidden'), 3000);
        }}
        function toggleMute() {{
            micOn = !micOn;
            document.getElementById('muteBtn').innerText = micOn ? '🎤 Micrófono: ON' : '🔇 Micrófono: MUTE';
        }}
        function endCall() {{
            document.getElementById('liveBadge').classList.add('hidden');
            document.getElementById('callStatusTitle').innerText = 'En Espera de Timbre';
            document.getElementById('callStatusSub').innerText = 'Extensión {html.escape(exten)}-webrtc lista • Notificaciones Push Activas';
        }}
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
