// Ground-truth probe: does the OpenAI Realtime API auto-continue after a
// server-side MCP call completes, or must the client send response.create?
//
// Mirrors VoiceKey's session.update shape (audio output, marin, Exa MCP).
// Injects the user turn as text. Phase A: after mcp_call completes, do
// NOTHING for WAIT_MS and observe. Phase B: send response.create and observe.
const WebSocket = require('ws');

const KEY = process.env.OPENAI_API_KEY;
if (!KEY) { console.error('no key in env'); process.exit(2); }

const WAIT_MS = 25000;
const url = 'wss://api.openai.com/v1/realtime?model=gpt-realtime-2';
const ws = new WebSocket(url, { headers: { Authorization: `Bearer ${KEY}` } });

let transcript = '';
let phase = 'setup';
let audioBytes = 0;
let mcpCompletedAt = null;
let phaseBTimer = null;

function send(obj) {
  console.log(`>>> SEND ${obj.type} (phase=${phase})`);
  ws.send(JSON.stringify(obj));
}

function sessionUpdate() {
  return {
    type: 'session.update',
    session: {
      type: 'realtime',
      model: 'gpt-realtime-2',
      output_modalities: ['audio'],
      audio: {
        input: {
          format: { type: 'audio/pcm', rate: 24000 },
          turn_detection: {
            type: 'semantic_vad', eagerness: 'auto',
            create_response: true, interrupt_response: true,
          },
        },
        output: { format: { type: 'audio/pcm', rate: 24000 }, voice: 'marin' },
      },
      instructions: 'You are a helpful voice assistant.',
      tools: [{
        type: 'mcp', server_label: 'exa',
        server_url: 'https://mcp.exa.ai/mcp',
        require_approval: 'never',
        allowed_tools: ['web_search_exa', 'web_fetch_exa'],
      }],
    },
  };
}

ws.on('open', () => console.log('=== ws open ==='));
ws.on('error', (e) => { console.error('WS ERROR', e.message); process.exit(1); });
ws.on('close', (c, r) => { console.log(`=== ws close ${c} ${r} ===`); });

ws.on('message', (raw) => {
  const ev = JSON.parse(raw.toString());
  const t = ev.type;

  if (t === 'response.output_audio.delta' || t === 'response.audio.delta') {
    audioBytes += (ev.delta || '').length;
    return; // don't spam
  }
  if (t === 'response.output_audio_transcript.delta') {
    transcript += ev.delta || '';
    return;
  }

  // Full payload for the interesting events; type-only for the rest.
  const interesting = ['error', 'response.done', 'response.created']
    .includes(t) || t.startsWith('response.mcp_call.') || t.startsWith('mcp_list_tools.')
    || t === 'response.output_item.done' || t === 'response.output_item.added';
  console.log(`<<< ${t}${interesting ? ' ' + JSON.stringify(ev).slice(0, 1200) : ''}`);

  if (t === 'session.created') {
    send(sessionUpdate());
  } else if (t === 'session.updated' && phase === 'setup') {
    phase = 'A-waiting-tools';
  } else if (t === 'mcp_list_tools.completed' && phase === 'A-waiting-tools') {
    phase = 'A';
    send({
      type: 'conversation.item.create',
      item: {
        type: 'message', role: 'user',
        content: [{ type: 'input_text', text: 'Search the web for the current top story on Hacker News and tell me its title.' }],
      },
    });
    send({ type: 'response.create' });
  } else if (t === 'response.mcp_call.completed') {
    mcpCompletedAt = Date.now();
    console.log(`*** mcp_call COMPLETED in phase ${phase}. transcript so far: "${transcript}" | audioBytes=${audioBytes}`);
    if (phase === 'A') {
      console.log(`*** PHASE A: doing NOTHING for ${WAIT_MS}ms to see if the server auto-continues...`);
      phaseBTimer = setTimeout(() => {
        console.log(`*** PHASE A RESULT: after ${WAIT_MS}ms silence — transcript: "${transcript}" | audioBytes=${audioBytes}`);
        console.log('*** PHASE B: sending response.create now');
        phase = 'B';
        transcript = ''; audioBytes = 0;
        send({ type: 'response.create' });
      }, WAIT_MS);
    }
  } else if (t === 'response.done') {
    const status = ev.response && ev.response.status;
    const itemTypes = ((ev.response && ev.response.output) || []).map(i => i.type).join(',');
    console.log(`*** response.done status=${status} items=[${itemTypes}] phase=${phase} transcript="${transcript}" audioBytes=${audioBytes}`);
    if (phase === 'A' && !mcpCompletedAt) {
      // response finished before any mcp completion — note it
      console.log('*** response.done arrived with no mcp_call completion yet');
    }
    if (phase === 'A' && mcpCompletedAt && transcript.length > 0) {
      console.log('*** SERVER AUTO-CONTINUED: model spoke after mcp_call without client action.');
      clearTimeout(phaseBTimer);
      finish();
    }
    if (phase === 'B') {
      console.log(`*** PHASE B RESULT: transcript="${transcript}" audioBytes=${audioBytes}`);
      finish();
    }
  } else if (t === 'error') {
    console.log('*** API ERROR — see payload above');
  }
});

function finish() {
  console.log('=== probe finished ===');
  ws.close();
  setTimeout(() => process.exit(0), 500);
}

setTimeout(() => { console.log('=== global timeout (120s) ==='); process.exit(3); }, 120000);
