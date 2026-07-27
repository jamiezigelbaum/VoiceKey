// Replays VoiceKey's exact OpenClaw gateway connect handshake (device-signed
// path) against a gateway and prints the outcome. Secrets are read locally
// and never printed.
//
// This is the tool that ground-truthed the pairing/auth contract recorded in
// docs/wo/WO_2026-07-24_021_service_picker_openclaw_wizard.md ("Verified
// facts"). Run it ON the Mac running the gateway — it reads that Mac's
// ~/.openclaw identity and secrets.
//
//   node scripts/dev/probe-openclaw-connect.js [ws://host:port]
//   node scripts/dev/probe-openclaw-connect.js --no-device-token
//
// --no-device-token reproduces the native repair for
// AUTH_DEVICE_TOKEN_MISMATCH: connect with the device signature + gateway
// token but no stored device token, and the gateway reissues the canonical
// one in hello-ok.auth.deviceToken.
const fs = require("fs");
const crypto = require("crypto");
const os = require("os");
const path = require("path");
const WebSocket = require(
  "/opt/homebrew/lib/node_modules/openclaw/node_modules/ws"
);

const home = os.homedir();
const idDir = path.join(home, ".openclaw", "identity");
const device = JSON.parse(fs.readFileSync(path.join(idDir, "device.json"), "utf8"));
const auth = JSON.parse(fs.readFileSync(path.join(idDir, "device-auth.json"), "utf8"));

if (auth.deviceId !== device.deviceId) {
  console.log("RESULT: device-auth deviceId mismatch — token belongs to a rotated identity");
  process.exit(2);
}
const operatorEntry = (auth.tokens || {}).operator || {};
const deviceToken = (operatorEntry.token || "").trim();
const scopes = operatorEntry.scopes || [];

// Gateway token: same resolution order VoiceKey uses on a headless box —
// ~/.openclaw/secrets/*gateway-token* file, else openclaw.json gateway.auth.token.
let gatewayToken = "";
const secretsDir = path.join(home, ".openclaw", "secrets");
if (fs.existsSync(secretsDir)) {
  for (const f of fs.readdirSync(secretsDir)) {
    if (f.includes("gateway-token")) {
      gatewayToken = fs.readFileSync(path.join(secretsDir, f), "utf8").trim();
      break;
    }
  }
}
if (!gatewayToken) {
  try {
    const cfg = JSON.parse(fs.readFileSync(path.join(home, ".openclaw", "openclaw.json"), "utf8"));
    const t = ((cfg.gateway || {}).auth || {}).token;
    if (typeof t === "string") gatewayToken = t.trim();
  } catch {}
}
// New secrets system: openclaw.json holds a secret *reference*; the value
// lives in ~/.openclaw/secrets.json under gateway.auth.token.
if (!gatewayToken) {
  try {
    const s = JSON.parse(fs.readFileSync(path.join(home, ".openclaw", "secrets.json"), "utf8"));
    const t = ((s.gateway || {}).auth || {}).token;
    if (typeof t === "string") gatewayToken = t.trim();
  } catch {}
}
console.log("device:", device.deviceId.slice(0, 12) + "…",
  "| deviceToken:", deviceToken ? "present" : "MISSING",
  "| gatewayToken:", gatewayToken ? "present" : "MISSING",
  "| scopes:", scopes.join(","));

const pubPem = device.publicKeyPem;
const privKey = crypto.createPrivateKey(device.privateKeyPem);
const rawPub = crypto.createPublicKey(pubPem).export({ type: "spki", format: "der" }).subarray(12);
const b64url = (b) => b.toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=/g, "");

const CLIENT_ID = "openclaw-macos", CLIENT_MODE = "backend", ROLE = "operator";
const omitDeviceToken = process.argv.includes("--no-device-token");
const endpoint = process.argv.slice(2).find((a) => a.startsWith("ws")) || "ws://127.0.0.1:18789";
const ws = new WebSocket(endpoint, { handshakeTimeout: 5000 });
const timer = setTimeout(() => { console.log("RESULT: timeout"); process.exit(3); }, 10000);

ws.on("message", (data) => {
  let frame;
  try { frame = JSON.parse(data.toString()); } catch { return; }
  if (frame.type === "event" && frame.event === "connect.challenge") {
    const nonce = (frame.payload || frame.params || {}).nonce;
    if (!nonce) { console.log("RESULT: challenge without nonce"); process.exit(4); }
    const signedAtMs = Date.now();
    const payload = ["v2", device.deviceId, CLIENT_ID, CLIENT_MODE, ROLE,
      scopes.join(","), String(signedAtMs), gatewayToken, nonce].join("|");
    const sig = crypto.sign(null, Buffer.from(payload, "utf8"), privKey);
    ws.send(JSON.stringify({
      type: "req", id: "1", method: "connect",
      params: {
        minProtocol: 1, maxProtocol: 4,
        client: { id: CLIENT_ID, version: "probe-1", platform: "macos", mode: CLIENT_MODE },
        caps: ["tool-events"],
        role: ROLE, scopes,
        device: { id: device.deviceId, publicKey: b64url(rawPub),
          signature: b64url(sig), signedAt: signedAtMs, nonce },
        auth: omitDeviceToken ? { token: gatewayToken } : { token: gatewayToken, deviceToken }
      }
    }));
    return;
  }
  if (frame.type === "res" && frame.id === "1") {
    if (frame.ok === false || frame.error) {
      console.log("RESULT: connect REJECTED:", JSON.stringify(frame.error || frame).slice(0, 600));
    } else {
      const r = frame.result || frame.payload || {};
      // Redact anything token-like before printing the hello shape.
      const redact = (v) => {
        if (Array.isArray(v)) return v.map(redact);
        if (v && typeof v === "object") {
          const o = {};
          for (const [k, val] of Object.entries(v)) {
            o[k] = /token|secret|key/i.test(k) && typeof val === "string"
              ? `<redacted:${val.length}ch>` : redact(val);
          }
          return o;
        }
        return v;
      };
      console.log("RESULT: connect OK");
      console.log("HELLO:", JSON.stringify(redact(r)).slice(0, 1500));
    }
    clearTimeout(timer);
    ws.close();
    process.exit(0);
  }
  // Print any other early frame heads for visibility (no payloads with secrets).
  if (frame.type === "event") {
    console.log("event:", frame.event);
  }
});
ws.on("close", (code, reason) => {
  console.log("CLOSE:", code, String(reason).slice(0, 300));
  clearTimeout(timer);
  process.exit(0);
});
ws.on("error", (e) => { console.log("ERROR:", e.message); });
