#!/usr/bin/env python3
"""
Script AGI / CLI para despertar celulares (Android FCM HTTP v1 / iOS APNs / Webhook)
al tocar timbre en el frente de calle KD9203.
Ubicación en el VPS: /var/lib/asterisk/agi-bin/push_wakeup.py

Soporta 2 modos sin dependencias externas (usa OpenSSL del sistema para firmar JWT de Firebase):
  1. Directo a Firebase Cloud Messaging (FCM HTTP v1):
     Colocando el archivo descargado de Firebase Console en:
     /etc/asterisk/firebase-service-account.json
  2. Webhook externo opcional (variable PUSH_WEBHOOK_URL).
"""

import base64
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

DEVICES_DB_PATH = "/etc/asterisk/push_devices.json"
FIREBASE_SA_PATH = "/etc/asterisk/firebase-service-account.json"
FCM_WEBHOOK_URL = os.environ.get("PUSH_WEBHOOK_URL", "")


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def get_firebase_access_token(sa_path: str) -> tuple[str, str]:
    """
    Obtiene un OAuth2 Access Token para Firebase FCM HTTP v1 firmando el JWT con openssl
    (no requiere instalar librerías pip en el VPS).
    Retorna (project_id, access_token).
    """
    with open(sa_path, "r", encoding="utf-8") as f:
        sa = json.load(f)

    project_id = sa["project_id"]
    client_email = sa["client_email"]
    private_key = sa["private_key"]

    now = int(time.time())
    header = b64url(json.dumps({"alg": "RS256", "typ": "JWT"}).encode("utf-8"))
    claim = b64url(
        json.dumps(
            {
                "iss": client_email,
                "scope": "https://www.googleapis.com/auth/firebase.messaging",
                "aud": "https://oauth2.googleapis.com/token",
                "iat": now,
                "exp": now + 3600,
            }
        ).encode("utf-8")
    )
    signing_input = f"{header}.{claim}".encode("ascii")

    with tempfile.NamedTemporaryFile("w", delete=False, encoding="utf-8") as key_file:
        key_file.write(private_key)
        key_path = key_file.name

    try:
        sig_bytes = subprocess.check_output(
            ["openssl", "dgst", "-sha256", "-sign", key_path],
            input=signing_input,
        )
    finally:
        if os.path.exists(key_path):
            os.remove(key_path)

    jwt_assertion = f"{header}.{claim}.{b64url(sig_bytes)}"
    form_data = urllib.parse.urlencode(
        {
            "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
            "assertion": jwt_assertion,
        }
    ).encode("utf-8")

    req = urllib.request.Request(
        "https://oauth2.googleapis.com/token",
        data=form_data,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=4) as resp:
        token_resp = json.loads(resp.read().decode("utf-8"))
    return project_id, token_resp["access_token"]


def send_fcm_v1_direct(
    project_id: str, access_token: str, device_token: str, data_payload: dict[str, str]
) -> None:
    """Envía un mensaje FCM HTTP v1 con prioridad ALTA (despierta Android Doze e iOS APNs)."""
    url = f"https://fcm.googleapis.com/v1/projects/{project_id}/messages:send"
    body = {
        "message": {
            "token": device_token,
            "data": data_payload,
            "android": {
                "priority": "HIGH",
                "ttl": "40s",
            },
            "apns": {
                "headers": {
                    "apns-priority": "10",
                    "apns-push-type": "background",
                },
                "payload": {
                    "aps": {
                        "content-available": 1,
                    }
                },
            },
        }
    }
    req = urllib.request.Request(
        url,
        data=json.dumps(body).encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {access_token}",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=4) as resp:
            resp.read()
    except urllib.error.URLError:
        pass


def load_devices(exten: str) -> list[dict]:
    if not os.path.exists(DEVICES_DB_PATH):
        return []
    try:
        with open(DEVICES_DB_PATH, "r", encoding="utf-8") as f:
            data = json.load(f)
        return data.get(str(exten), [])
    except Exception:
        return []


def send_push_notification(exten: str, caller: str) -> None:
    devices = load_devices(exten)
    if not devices and not FCM_WEBHOOK_URL:
        return

    timestamp = str(int(time.time()))
    caller_name = "Portero Edificio" if str(caller) == "8000" else f"Depto {caller}"
    data_payload = {
        "extension": str(exten),
        "caller": str(caller),
        "caller_name": caller_name,
        "type": "incoming_intercom_call",
        "priority": "high",
        "video": "true",
        "dtmf_unlock": "#",
        "timestamp": timestamp,
    }

    # 1. Envío directo a Firebase Cloud Messaging HTTP v1 si existe /etc/asterisk/firebase-service-account.json
    if devices and os.path.exists(FIREBASE_SA_PATH):
        try:
            project_id, access_token = get_firebase_access_token(FIREBASE_SA_PATH)
            for dev in devices:
                tok = dev.get("token", "")
                if tok:
                    send_fcm_v1_direct(project_id, access_token, tok, data_payload)
        except Exception:
            pass

    # 2. Envío opcional a Webhook externo
    if FCM_WEBHOOK_URL:
        webhook_body = {**data_payload, "devices": devices}
        req = urllib.request.Request(
            FCM_WEBHOOK_URL,
            data=json.dumps(webhook_body).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=3) as resp:
                resp.read()
        except urllib.error.URLError:
            pass


def main() -> None:
    exten = sys.argv[1] if len(sys.argv) > 1 else ""
    caller = sys.argv[2] if len(sys.argv) > 2 else "8000"
    if exten:
        send_push_notification(exten, caller)


if __name__ == "__main__":
    main()
