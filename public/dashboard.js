const terminalElement = document.querySelector('#terminal');
const form = document.querySelector('#connectForm');
const codeInput = document.querySelector('#code');
const disconnectButton = document.querySelector('#disconnect');
const alertForm = document.querySelector('#alertForm');
const commandForm = document.querySelector('#commandForm');
const commandInput = document.querySelector('#commandInput');
const sendCommandButton = document.querySelector('#sendCommand');
const alertKindInput = document.querySelector('#alertKind');
const alertMessageInput = document.querySelector('#alertMessage');
const sendAlertButton = document.querySelector('#sendAlert');
const statusElement = document.querySelector('#status');

const term = new Terminal({
  cursorBlink: true,
  convertEol: true,
  fontFamily: 'Menlo, Monaco, Consolas, "Liberation Mono", monospace',
  fontSize: 14,
  theme: {
    background: '#101214',
    foreground: '#f4f1e8',
    cursor: '#e6c86e'
  }
});
const fitAddon = new FitAddon.FitAddon();

let socket = null;

term.loadAddon(fitAddon);
term.open(terminalElement);
fitAddon.fit();
term.writeln('FriendShell dashboard ready.');

function setStatus(message) {
  statusElement.textContent = message;
}

function setConnected(connected) {
  codeInput.disabled = connected;
  form.querySelector('button[type="submit"]').disabled = connected;
  disconnectButton.disabled = !connected;
  alertKindInput.disabled = !connected;
  alertMessageInput.disabled = !connected;
  sendAlertButton.disabled = !connected;
  commandInput.disabled = !connected;
  sendCommandButton.disabled = !connected;
}

function focusTerminal() {
  requestAnimationFrame(() => term.focus());
}

function socketUrl() {
  const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
  return `${protocol}//${window.location.host}`;
}

function sendBytes(text) {
  if (!socket || socket.readyState !== WebSocket.OPEN) return;
  socket.send(new TextEncoder().encode(text));
}

form.addEventListener('submit', (event) => {
  event.preventDefault();
  const code = codeInput.value.trim();
  if (!/^\d{6}$/.test(code)) {
    setStatus('Enter a valid 6-digit code.');
    return;
  }

  socket = new WebSocket(socketUrl());
  socket.binaryType = 'arraybuffer';
  setStatus('Connecting...');
  setConnected(true);
  term.clear();

  socket.addEventListener('open', () => {
    socket.send(JSON.stringify({ role: 'dashboard', code }));
    setStatus('Waiting for helper...');
  });

  socket.addEventListener('message', (event) => {
    if (typeof event.data === 'string') {
      const message = JSON.parse(event.data);
      if (message.type === 'registered') setStatus('Waiting for helper...');
      if (message.type === 'paired') {
        setStatus('Connected. Click the terminal or use the command box to type.');
        focusTerminal();
      }
      if (message.type === 'disconnect') setStatus(message.reason || 'Disconnected.');
      if (message.type === 'error') setStatus(message.message);
      if (message.type === 'alert') term.writeln(`\r\n[${message.kind || 'alert'}] ${message.message}`);
      return;
    }

    term.write(new Uint8Array(event.data));
  });

  socket.addEventListener('close', () => {
    setConnected(false);
    setStatus('Disconnected.');
    socket = null;
  });

  socket.addEventListener('error', () => {
    setStatus('Connection error.');
  });
});

term.onData(sendBytes);
terminalElement.addEventListener('pointerdown', focusTerminal);
terminalElement.addEventListener('click', focusTerminal);

commandForm.addEventListener('submit', (event) => {
  event.preventDefault();
  const command = commandInput.value;
  if (!command || !socket || socket.readyState !== WebSocket.OPEN) return;
  sendBytes(`${command}\n`);
  commandInput.value = '';
  focusTerminal();
});

alertForm.addEventListener('submit', (event) => {
  event.preventDefault();
  const message = alertMessageInput.value.trim();
  if (!message || !socket || socket.readyState !== WebSocket.OPEN) return;
  socket.send(JSON.stringify({
    type: 'alert',
    kind: alertKindInput.value === 'notification' ? 'notification' : 'alert',
    message
  }));
  alertMessageInput.value = '';
  setStatus('Alert sent.');
  focusTerminal();
});

disconnectButton.addEventListener('click', () => {
  if (socket) {
    socket.send(JSON.stringify({ type: 'disconnect' }));
    socket.close(1000, 'requested disconnect');
  }
});

window.addEventListener('load', focusTerminal);

window.addEventListener('resize', () => fitAddon.fit());
