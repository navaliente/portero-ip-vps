/**
 * Servidor Local en Vivo para Pruebas del Videoportero IP (Hikvision DS-KD9203-ME6 + VPS Asterisk)
 * - Sirve la interfaz interactiva en http://localhost:8090 (Contexto seguro para WebRTC + Micrófono)
 * - Conecta en vivo con el portero físico en http://192.168.100.186 (Cámara HD, Estado de Timbre, Relé de Puerta)
 * - Conecta por WebRTC (JsSIP) con el VPS en wss://vps-6615824-x.dattaweb.com/ws
 */

const http = require('http');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const PORT = 8090;
const KD_HOST = process.env.KD_HOST || '192.168.100.186';
const KD_USER = process.env.KD_USER || 'admin';
const KD_PASS = process.env.KD_PASS || '1234567a';

function md5(str) {
  return crypto.createHash('md5').update(str).digest('hex');
}

function makeDigestHeader(method, uri, wwwAuth) {
  const realmMatch = /realm="([^"]+)"/i.exec(wwwAuth);
  const nonceMatch = /nonce="([^"]+)"/i.exec(wwwAuth);
  const qopMatch = /qop="([^"]+)"/i.exec(wwwAuth);
  const realm = realmMatch ? realmMatch[1] : '';
  const nonce = nonceMatch ? nonceMatch[1] : '';
  const qop = qopMatch ? qopMatch[1].split(',')[0].trim() : '';
  const nc = '00000001';
  const cnonce = crypto.randomBytes(8).toString('hex');

  const ha1 = md5(`${KD_USER}:${realm}:${KD_PASS}`);
  const ha2 = md5(`${method}:${uri}`);
  let response;
  if (qop) {
    response = md5(`${ha1}:${nonce}:${nc}:${cnonce}:${qop}:${ha2}`);
    return `Digest username="${KD_USER}", realm="${realm}", nonce="${nonce}", uri="${uri}", qop=${qop}, nc=${nc}, cnonce="${cnonce}", response="${response}"`;
  } else {
    response = md5(`${ha1}:${nonce}:${ha2}`);
    return `Digest username="${KD_USER}", realm="${realm}", nonce="${nonce}", uri="${uri}", response="${response}"`;
  }
}

function kdRequest(method, uri, body = null, contentType = 'application/json') {
  return new Promise((resolve, reject) => {
    const opts1 = { host: KD_HOST, port: 80, path: uri, method, timeout: 4000 };
    const req1 = http.request(opts1, (res1) => {
      res1.resume();
      if (res1.statusCode !== 401 || !res1.headers['www-authenticate']) {
        let chunks = [];
        res1.on('data', (d) => chunks.push(d));
        res1.on('end', () => resolve({ status: res1.statusCode, headers: res1.headers, data: Buffer.concat(chunks) }));
        return;
      }
      const authHeader = makeDigestHeader(method, uri, res1.headers['www-authenticate']);
      const headers = { Authorization: authHeader };
      if (body) {
        headers['Content-Type'] = contentType;
        headers['Content-Length'] = Buffer.byteLength(body);
      }
      const opts2 = { host: KD_HOST, port: 80, path: uri, method, headers, timeout: 4000 };
      const req2 = http.request(opts2, (res2) => {
        let chunks = [];
        res2.on('data', (d) => chunks.push(d));
        res2.on('end', () => resolve({ status: res2.statusCode, headers: res2.headers, data: Buffer.concat(chunks) }));
      });
      req2.on('error', reject);
      if (body) req2.write(body);
      req2.end();
    });
    req1.on('error', reject);
    req1.end();
  });
}

const server = http.createServer(async (req, res) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, PUT, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
  if (req.method === 'OPTIONS') {
    res.writeHead(204);
    res.end();
    return;
  }

  const urlObj = new URL(req.url, `http://localhost:${PORT}`);

  // 1. Snapshot en vivo de la cámara H.264 del DS-KD9203-ME6
  if (urlObj.pathname === '/api/snapshot.jpg') {
    try {
      const r = await kdRequest('GET', '/ISAPI/Streaming/channels/101/picture');
      res.writeHead(r.status === 200 ? 200 : 502, {
        'Content-Type': 'image/jpeg',
        'Cache-Control': 'no-store, no-cache, must-revalidate'
      });
      res.end(r.data);
    } catch (e) {
      res.writeHead(502, { 'Content-Type': 'text/plain' });
      res.end('Error conectando a la camara del KD9203: ' + e.message);
    }
    return;
  }

  // 2. Estado en vivo del timbre y registro SIP del DS-KD9203-ME6
  if (urlObj.pathname === '/api/status') {
    try {
      const [callRes, sipRes] = await Promise.all([
        kdRequest('GET', '/ISAPI/VideoIntercom/callStatus?format=json'),
        kdRequest('GET', '/ISAPI/System/Network/SIP')
      ]);
      let callStatus = 'idle';
      try {
        const j = JSON.parse(callRes.data.toString('utf8'));
        if (j && j.CallStatus && j.CallStatus.status) callStatus = j.CallStatus.status;
      } catch (_) {}
      const sipXml = sipRes.data.toString('utf8');
      const registered = sipXml.includes('<registerStatus>true</registerStatus>');
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: true, callStatus, registered, kdHost: KD_HOST }));
    } catch (e) {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: false, callStatus: 'offline', registered: false, error: e.message }));
    }
    return;
  }

  // 3. Abrir Puerta Real (Relé 1 o 2 del DS-KD9203-ME6)
  if (urlObj.pathname === '/api/unlock' && req.method === 'POST') {
    try {
      const xml = '<?xml version="1.0" encoding="UTF-8"?><RemoteControlDoor version="2.0" xmlns="http://www.isapi.org/ver20/XMLSchema"><cmd>open</cmd></RemoteControlDoor>';
      const r = await kdRequest('PUT', '/ISAPI/AccessControl/RemoteControl/door/1', xml, 'application/xml');
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: r.status === 200, status: r.status, response: r.data.toString('utf8') }));
    } catch (e) {
      res.writeHead(500, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: false, error: e.message }));
    }
    return;
  }

  // 4. Atender o Cortar llamada física en el DS-KD9203-ME6 (ISAPI callSignal)
  if (urlObj.pathname === '/api/callsignal' && req.method === 'POST') {
    let body = '';
    req.on('data', (c) => (body += c));
    req.on('end', async () => {
      try {
        const parsed = JSON.parse(body || '{}');
        const cmdType = parsed.cmdType || 'answer';
        const payload = JSON.stringify({ CallSignal: { cmdType } });
        const r = await kdRequest('PUT', '/ISAPI/VideoIntercom/callSignal?format=json', payload, 'application/json');
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: r.status === 200, status: r.status, response: r.data.toString('utf8') }));
      } catch (e) {
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: false, error: e.message }));
      }
    });
    return;
  }

  // 5. Descarga directa del APK por Wi-Fi Local a máxima velocidad
  if (urlObj.pathname === '/portero-ip-edificio.apk') {
    const apkPath = path.join(__dirname, '..', 'portero-ip-edificio.apk');
    if (!fs.existsSync(apkPath)) {
      res.writeHead(404);
      res.end('APK no encontrado');
      return;
    }
    const stat = fs.statSync(apkPath);
    res.writeHead(200, {
      'Content-Type': 'application/vnd.android.package-archive',
      'Content-Disposition': 'attachment; filename="portero-ip-edificio.apk"',
      'Content-Length': stat.size
    });
    fs.createReadStream(apkPath).pipe(res);
    return;
  }

  // 6. Servir la interfaz interactiva en vivo
  const htmlPath = path.join(__dirname, 'vista_previa_interactiva.html');
  fs.readFile(htmlPath, (err, content) => {
    if (err) {
      res.writeHead(500);
      res.end('Error leyendo vista_previa_interactiva.html');
      return;
    }
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-cache' });
    res.end(content);
  });
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`[OK] Servidor en Vivo corriendo en http://localhost:${PORT}`);
});

