// Ground-truth probe: the client-side interruption dance on the GA Realtime
// endpoint. Start an audio response, then mid-stream send response.cancel and
// conversation.item.truncate — record exact accepted shapes / errors.
const WebSocket = require('ws');
const KEY = process.env.OPENAI_API_KEY;
if (!KEY) { console.error('no key'); process.exit(2); }

const ws = new WebSocket('wss://api.openai.com/v1/realtime?model=gpt-realtime-2',
  { headers: { Authorization: `Bearer ${KEY}` } });

let assistantItemId = null;
let audioMs = 0;          // ms of audio received (24kHz pcm16 mono: 48 bytes/ms)
let cancelled = false;
let phase = 'setup';

function send(o) { console.log('>>>', JSON.stringify(o).slice(0, 200)); ws.send(JSON.stringify(o)); }

ws.on('error', e => { console.error('WS ERROR', e.message); process.exit(1); });
ws.on('message', raw => {
  const ev = JSON.parse(raw.toString());
  const t = ev.type;
  if (t === 'session.created') {
    send({ type: 'session.update', session: { type: 'realtime', output_modalities: ['audio'],
      audio: { output: { format: { type: 'audio/pcm', rate: 24000 }, voice: 'marin' } },
      instructions: 'Answer at length, slowly.' } });
  } else if (t === 'session.updated' && phase === 'setup') {
    phase = 'running';
    send({ type: 'conversation.item.create', item: { type: 'message', role: 'user',
      content: [{ type: 'input_text', text: 'Tell me a long story about the sea, at least a minute long.' }] } });
    send({ type: 'response.create' });
  } else if (t === 'response.output_item.added' && ev.item && ev.item.type === 'message') {
    assistantItemId = ev.item.id;
    console.log('<<< assistant item id =', assistantItemId);
  } else if (t === 'response.output_audio.delta') {
    const bytes = Buffer.from(ev.delta || '', 'base64').length;
    audioMs += bytes / 48;
    if (audioMs > 1500 && !cancelled) {
      cancelled = true;
      console.log(`*** ${Math.round(audioMs)}ms of audio received — interrupting now`);
      send({ type: 'response.cancel' });
      send({ type: 'conversation.item.truncate', item_id: assistantItemId,
             content_index: 0, audio_end_ms: 1000 });
    }
  } else if (['response.cancelled', 'conversation.item.truncated', 'error',
              'response.done'].includes(t)) {
    console.log('<<<', t, JSON.stringify(ev).slice(0, 500));
    if (t === 'response.done') {
      console.log(`*** final: response.status=${ev.response && ev.response.status}`);
      setTimeout(() => { ws.close(); process.exit(0); }, 1500);
    }
  }
});
setTimeout(() => { console.log('=== timeout ==='); process.exit(3); }, 60000);
