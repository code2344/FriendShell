# FriendShell

FriendShell is a simple consent-based remote terminal support tool. A macOS helper connects outbound to a Node.js server, and a browser dashboard pairs with it using a random 6-digit session code.

The helper shows this warning before connecting:

> Only run this if you trust the person helping you. They will be able to run terminal commands as your user account.

## What is included

- Node.js server using Express and ws
- Browser dashboard using xterm.js from npm, served locally by Express. No Homebrew xterm install is needed
- macOS Swift helper app source in `Helper/` with a visible warning, session code, Start button, and Disconnect button
- One helper and one dashboard paired by a 6-digit code
- Outbound-only helper connection over WebSocket/WSS
- `/bin/zsh -i` launched as the current user with `Process`
- stdout and stderr captured with `Pipe`
- stdin written from dashboard WebSocket messages
- Disconnect controls on both sides
- Dashboard messages shown on the helper Mac through `/usr/bin/osascript` as either `display dialog` popups or `display notification` banners
- Connection and disconnection logging on the server

## Setup

Install dependencies:

```sh
npm install
```

This installs the browser terminal library from npm into `node_modules`. You do not need to install xterm with Homebrew or any other system package manager.

Run the server for local debugging:

```sh
npm run dev
```

Debug mode binds to `localhost:3000`.

Run the server for production-style use:

```sh
npm start
```

Production mode binds to `0.0.0.0:3000`. Set `PORT` or `HOST` if needed:

```sh
PORT=8080 HOST=0.0.0.0 npm start
```

## Dashboard

Open the dashboard in a browser:

```text
http://localhost:3000
```

Enter the 6-digit code shown by the helper, then click Connect.

The dashboard has two ways to send terminal input: click inside the terminal and type, or use the command box below the terminal and press Enter.

## Helper

Run the helper from source:

```sh
npm run helper:run
```

The helper window shows the warning, generates a 6-digit code, and lets the user click Start or Disconnect. By default it connects to:

```text
ws://localhost:3000
```

For a hosted server, pass a WSS URL or type it into the helper window:

```sh
FRIENDSHELL_SERVER=wss://your-domain.example npm run helper:run
```

Build `Helper.app`:

```sh
npm run helper:app
```

The app bundle is created at:

```text
Helper.app
```

The helper does not require admin. It runs commands only as the current macOS user.

## Safety notes

Only share a session code with someone you trust. The dashboard user can run terminal commands as the macOS user running the helper until either side disconnects.

For real production use, put the Node.js server behind HTTPS so browser and helper traffic use WSS.
