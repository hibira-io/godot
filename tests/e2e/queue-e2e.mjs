// Cross-play matchmaking test: HibiraQueue (tests/queue_e2e.gd, run in a
// headless Godot) waits in one queue with @hibira-io/lobby players on a real
// server, for example a local pusher-server with client events on:
//
//   cd tests/e2e && npm install
//   GODOT=godot E2E_HOST=127.0.0.1 E2E_PORT=6001 E2E_TLS=0 \
//   E2E_APP_ID=... E2E_KEY=... E2E_SECRET=... npm run test:queue
//
// By default Godot (rating 1000) joins first and hosts: a JS player rated 5000
// must be left waiting, and a JS player rated 1030 must be matched with Godot
// and meet it in the match room. JS_FIRST=1 lets the JS player host instead.
import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import PusherClient from 'pusher-js';
import PusherServer from 'pusher';
import { Queue } from '@hibira-io/lobby';
import { authorizeQueue, authorizeRoom } from '@hibira-io/lobby/server';

const env = process.env;
for (const k of ['E2E_APP_ID', 'E2E_KEY', 'E2E_SECRET']) {
  if (!env[k]) {
    console.error(`set ${k}`);
    process.exit(2);
  }
}
const host = env.E2E_HOST ?? '127.0.0.1';
const port = Number(env.E2E_PORT ?? 6001);
const tls = env.E2E_TLS === '1';
const hibira = new PusherServer({ appId: env.E2E_APP_ID, key: env.E2E_KEY, secret: env.E2E_SECRET, host, port: String(port), useTLS: tls });
const channel = `presence-queue-E2E${Date.now().toString(36).toUpperCase()}`;

function sign({ socketId, channel: ch, userId, name, rating }) {
  const req = { socketId, channel: ch, userId, userInfo: { name } };
  return ch.startsWith('presence-queue-') ? authorizeQueue(hibira, { ...req, rating }) : authorizeRoom(hibira, req);
}

const auth = createServer((req, res) => {
  let body = '';
  req.on('data', (c) => (body += c));
  req.on('end', async () => {
    const form = new URLSearchParams(body);
    try {
      const signed = await sign({
        socketId: form.get('socket_id'),
        channel: form.get('channel_name'),
        userId: form.get('user_id'),
        name: form.get('name'),
        rating: Number(form.get('rating')),
      });
      res.writeHead(200, { 'content-type': 'application/json' }).end(JSON.stringify(signed));
    } catch (err) {
      res.writeHead(500, { 'content-type': 'application/json' }).end(JSON.stringify({ error: err.message }));
    }
  });
});
await new Promise((r) => auth.listen(0, '127.0.0.1', r));
const authUrl = `http://127.0.0.1:${auth.address().port}/auth`;
const fail = (msg) => { console.error(`js: FAIL ${msg}`); process.exit(1); };
const timeout = setTimeout(() => fail('timed out'), 45000);
const jsFirst = env.JS_FIRST === '1';

function player(userId, name, rating) {
  return new PusherClient(env.E2E_KEY, {
    cluster: 'mt1', wsHost: host, wsPort: port, wssPort: port, forceTLS: tls, enabledTransports: ['ws'],
    channelAuthorization: { customHandler: ({ socketId, channelName }, cb) =>
      sign({ socketId, channel: channelName, userId, name, rating }).then((a) => cb(null, a), (e) => cb(e, null)) },
  });
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

let near, nearQueue, matchP;
const startNear = () => {
  near = player('u-js-near', 'Bea', 1030);
  nearQueue = Queue.join(near, channel, { size: 2, ratingRange: 100, timeout: 30000 });
  matchP = new Promise((resolve) => nearQueue.on('match', resolve));
};
if (jsFirst) { startNear(); await new Promise((r) => nearQueue.on('ready', r)); console.log('js: near player hosts'); }

const godot = spawn(env.GODOT ?? 'godot', ['--headless', '--path', fileURLToPath(new URL('../..', import.meta.url)), '--script', 'res://tests/queue_e2e.gd'], {
  env: { ...env, E2E_AUTH_URL: authUrl, E2E_CHANNEL: channel }, stdio: ['ignore', 'pipe', 'inherit'],
});
let onJoined; const godotJoined = new Promise((r) => (onJoined = r));
let buf = '';
godot.stdout.on('data', (d) => {
  buf += d; let i;
  while ((i = buf.indexOf('\n')) >= 0) {
    const line = buf.slice(0, i).trim(); buf = buf.slice(i + 1);
    if (line) console.log(`godot: ${line}`);
    if (line.startsWith('JOINED')) onJoined(line);
  }
});
const godotExit = new Promise((r) => godot.on('exit', r));
const joinedLine = await godotJoined;
if (joinedLine !== `JOINED host=${jsFirst ? 'false' : 'true'}`) fail(`unexpected ${joinedLine}`);
let far, farQueue;
if (!jsFirst) {
  await sleep(300);
  far = player('u-js-far', 'Fay', 5000);
  farQueue = Queue.join(far, channel, { size: 2, ratingRange: 100, timeout: 30000 });
  farQueue.on('match', (m) => fail(`far player matched with ${m.players.map((p) => p.id)}`));
  await sleep(500);
  startNear();
}
const match = await matchP;
const ids = match.players.map((p) => p.id).sort().join(',');
if (ids !== 'u-godot,u-js-near') fail(`near player matched with ${ids}`);
console.log(`js: matched ${ids} in ${match.channel}`);
await new Promise((resolve) => {
  const seen = () => match.room.players.some((p) => p.id === 'u-godot') && resolve();
  match.room.on('ready', seen); match.room.on('members', seen);
});
console.log('js: met the Godot player in the match room');
if (farQueue && farQueue.status !== 'waiting') fail(`far status ${farQueue.status}`);
const code = await godotExit;
clearTimeout(timeout);
farQueue?.leave(); match.room.leave(); far?.disconnect(); near.disconnect(); auth.close();
if (code !== 0) fail(`Godot exited ${code}`);
console.log(`PASS: ${jsFirst ? '@hibira-io/lobby hosted, Godot followed' : 'Godot hosted and matched a @hibira-io/lobby player by rating'}`);
process.exit(0);
