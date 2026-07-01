import express from 'express';
import http from 'http';
import path from 'path';
import { fileURLToPath } from 'url';
import { WebSocketServer } from 'ws';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const rootDir = path.resolve(__dirname, '..');

const app = express();
const server = http.createServer(app);
const wss = new WebSocketServer({ server });

const port = Number(process.env.PORT || 3000);
const isProd = process.env.NODE_ENV === 'production';
const host = process.env.HOST || (isProd ? '0.0.0.0' : '127.0.0.1');

const sessions = new Map();
const OPEN = 1;

app.use(express.static(path.join(rootDir, 'public')));
app.use('/vendor/xterm', express.static(path.join(rootDir, 'node_modules/@xterm/xterm')));
app.use('/vendor/xterm-fit', express.static(path.join(rootDir, 'node_modules/@xterm/addon-fit')));

function log(message, details = '') {
  const suffix = details ? ` ${details}` : '';
  console.log(`[${new Date().toISOString()}] ${message}${suffix}`);
}

function getSession(code) {
  if (!sessions.has(code)) {
    sessions.set(code, { helper: null, dashboard: null });
  }
  return sessions.get(code);
}

function safeSend(ws, data) {
  if (ws && ws.readyState === OPEN) {
    ws.send(data);
  }
}

function sendJson(ws, value) {
  safeSend(ws, JSON.stringify(value));
}

function closePeer(peer, reason) {
  if (peer && peer.readyState === OPEN) {
    sendJson(peer, { type: 'disconnect', reason });
    peer.close(1000, reason);
  }
}

function peerFor(ws) {
  const { code, role } = ws.friendShell;
  const session = sessions.get(code);
  return role === 'helper' ? session?.dashboard : session?.helper;
}

function cleanup(ws) {
  const { code, role } = ws.friendShell || {};
  if (!code || !role) return;

  const session = sessions.get(code);
  if (!session) return;

  if (session[role] === ws) {
    session[role] = null;
  }

  const peerRole = role === 'helper' ? 'dashboard' : 'helper';
  const peer = session[peerRole];
  session[peerRole] = null;

  log(`${role} disconnected`, `code=${code}`);
  closePeer(peer, `${role} disconnected`);

  if (!session.helper && !session.dashboard) {
    sessions.delete(code);
  }
}

function register(ws, role, code) {
  if (!/^\d{6}$/.test(code)) {
    sendJson(ws, { type: 'error', message: 'Session code must be 6 digits.' });
    ws.close(1008, 'invalid code');
    return;
  }

  if (role !== 'helper' && role !== 'dashboard') {
    sendJson(ws, { type: 'error', message: 'Role must be helper or dashboard.' });
    ws.close(1008, 'invalid role');
    return;
  }

  const session = getSession(code);
  if (session[role] && session[role].readyState === OPEN) {
    sendJson(ws, { type: 'error', message: `A ${role} is already connected for this code.` });
    ws.close(1008, 'duplicate role');
    return;
  }

  ws.friendShell = { role, code };
  session[role] = ws;
  log(`${role} connected`, `code=${code}`);
  sendJson(ws, { type: 'registered', role, code });

  if (session.helper && session.dashboard) {
    sendJson(session.helper, { type: 'paired' });
    sendJson(session.dashboard, { type: 'paired' });
    log('session paired', `code=${code}`);
  }
}

wss.on('connection', (ws) => {
  ws.on('message', (data, isBinary) => {
    if (!ws.friendShell) {
      if (isBinary) {
        ws.close(1008, 'expected registration');
        return;
      }

      let message;
      try {
        message = JSON.parse(data.toString());
      } catch {
        ws.close(1008, 'invalid registration');
        return;
      }

      register(ws, message.role, String(message.code || ''));
      return;
    }

    if (!isBinary) {
      let message;
      try {
        message = JSON.parse(data.toString());
      } catch {
        return;
      }

      if (message.type === 'disconnect') {
        ws.close(1000, 'requested disconnect');
        return;
      }

      if (message.type === 'alert' && typeof message.message === 'string') {
        safeSend(peerFor(ws), JSON.stringify({
          type: 'alert',
          kind: message.kind === 'notification' ? 'notification' : 'alert',
          message: message.message.slice(0, 500)
        }));
      }
      return;
    }

    safeSend(peerFor(ws), data);
  });

  ws.on('close', () => cleanup(ws));
  ws.on('error', (error) => log('websocket error', error.message));
});

server.listen(port, host, () => {
  log('FriendShell server listening', `http://${host}:${port}`);
});
