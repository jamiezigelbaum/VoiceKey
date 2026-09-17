// Ground-truth probe: which echo/barge-in-relevant session fields does the
// real Realtime endpoint accept, and what does session.updated echo back?
// Sends a sequence of session.update variants and prints the echoed audio
// input config or the error for each.
const WebSocket = require('ws');

const KEY = process.env.OPENAI_API_KEY;
if (!KEY) { console.error('no key'); process.exit(2); }

const url = 'wss://api.openai.com/v1/realtime?model=gpt-realtime-2';
const ws = new WebSocket(url, { headers: { Authorization: `Bearer ${KEY}` } });

const variants = [
  ['noise_reduction far_field', {
    audio: { input: { noise_reduction: { type: 'far_field' } } },
  }],
  ['noise_reduction near_field', {
    audio: { input: { noise_reduction: { type: 'near_field' } } },
  }],
  ['semantic_vad eagerness=low, interrupt_response=false', {
    audio: { input: { turn_detection: {
      type: 'semantic_vad', eagerness: 'low',
      create_response: true, interrupt_response: false,
    } } },
  }],
  ['server_vad threshold=0.8 prefix=300 silence=700', {
    audio: { input: { turn_detection: {
      type: 'server_vad', threshold: 0.8,
      prefix_padding_ms: 300, silence_duration_ms: 700,
      create_response: true, interrupt_response: true,
    } } },
  }],
  ['turn_detection=null (client-controlled turns)', {
    audio: { input: { turn_detection: null } },
  }],
];

let i = -1;
function next() {
  i += 1;
  if (i >= variants.length) { console.log('=== all variants probed ==='); ws.close(); setTimeout(() => process.exit(0), 300); return; }
  const [label, session] = variants[i];
  console.log(`\n### VARIANT ${i}: ${label}`);
  ws.send(JSON.stringify({ type: 'session.update', session: { type: 'realtime', ...session } }));
}

ws.on('open', () => {});
ws.on('error', (e) => { console.error('WS ERROR', e.message); process.exit(1); });
ws.on('message', (raw) => {
  const ev = JSON.parse(raw.toString());
  if (ev.type === 'session.created') { next(); return; }
  if (ev.type === 'session.updated') {
    const input = ev.session && ev.session.audio && ev.session.audio.input;
    console.log('ACCEPTED. echoed audio.input =', JSON.stringify({
      noise_reduction: input && input.noise_reduction,
      turn_detection: input && input.turn_detection,
    }));
    next();
  } else if (ev.type === 'error') {
    console.log('REJECTED.', JSON.stringify(ev.error).slice(0, 400));
    next();
  }
});
setTimeout(() => { console.log('=== timeout ==='); process.exit(3); }, 60000);
