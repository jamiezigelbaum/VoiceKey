// Repairs ~/.openclaw/identity/device-auth.json after a gateway upgrade
// invalidated the stored operator device token (AUTH_DEVICE_TOKEN_MISMATCH).
//
// This mirrors the official OpenClaw client's own behavior: connect to the
// local gateway with the device identity + gateway token (no device token),
// receive the canonical reissued device token in the hello payload
// (hello-ok.auth.deviceToken), and persist it to the device-auth store.
// A timestamped backup of the store is made before writing.
//
// Run it ON the Mac running the gateway:
//   node scripts/dev/repair-openclaw-device-auth.js
//
// VoiceKey itself performs the same no-device-token retry in memory and never
// writes to these files; this script is for repairing the OpenClaw CLI's own
// stored credentials. Diagnose first with probe-openclaw-connect.js.
const fs = require("fs");
const crypto = require("crypto");
const os = require("os");
const path = require("path");
const WebSocket = require(
  "/opt/homebrew/lib/node_modules/openclaw/node_modules/ws"
);

const home = os.homedir();
const idDir = path.join(home, ".openclaw", "identity");
const authPath = path.join(idDir, "device-auth.json");
const device = JSON.parse(fs.readFileSync(path.join(idDir, "device.json"), "utf8"));
const store = JSON.parse(fs.readFileSync(authPath, "utf8"));
const scopes = ((store.tokens || {}).operator || {}).scopes || [];

const secrets = JSON.parse(fs.readFileSync(path.join(home, ".openclaw", "secrets.json"), "utf8"));
const gatewayToken = (((secrets.gateway || {}).auth || {}).token || "").trim();
if (!gatewayToken) { console.log("FAIL: no gateway token in secrets.json"); process.exit(1); }

const privKey = crypto.createPrivateKey(device.privateKeyPem);
const rawPub = crypto.createPublicKey(device.publicKeyPem)
  .export({ type: "spki", format: "der" }).subarray(12);
const b64url = (b) => b.toString("base64")
  .replace(/\+/g, "-").replace(/\//g, "_").replace(/=/g, "");

const CLIENT_ID = "openclaw-macos", CLIENT_MODE = "backend", ROLE = "operator";
const ws = new WebSocket("ws://127.0.0.1:18789", { handshakeTimeout: 5000 });
setTimeout(() => { console.log("FAIL: timeout"); process.exit(3); }, 10000);

ws.on("message", (data) => {
  let frame;
  try { frame = JSON.parse(data.toString()); } catch { return; }
  if (frame.type === "event" && frame.event === "connect.challenge") {
    const nonce = (frame.payload || {}).nonce;
    const signedAtMs = Date.now();
    const payload = ["v2", device.deviceId, CLIENT_ID, CLIENT_MODE, ROLE,
      scopes.join(","), String(signedAtMs), gatewayToken, nonce].join("|");
    const sig = crypto.sign(null, Buffer.from(payload, "utf8"), privKey);
    ws.send(JSON.stringify({
      type: "req", id: "1", method: "connect",
      params: {
        minProtocol: 1, maxProtocol: 4,
        client: { id: CLIENT_ID, version: "repair-1", platform: "macos", mode: CLIENT_MODE },
        caps: ["tool-events"],
        role: ROLE, scopes,
        device: { id: device.deviceId, publicKey: b64url(rawPub),
          signature: b64url(sig), signedAt: signedAtMs, nonce },
        auth: { token: gatewayToken } // no stale deviceToken: gateway reissues
      }
    }));
    return;
  }
  if (frame.type === "res" && frame.id === "1") {
    if (frame.ok === false || frame.error) {
      console.log("FAIL: connect rejected:", JSON.stringify(frame.error).slice(0, 400));
      process.exit(4);
    }
    const auth = (frame.result || {}).auth || {};
    if (!auth.deviceToken) { console.log("FAIL: hello carried no deviceToken"); process.exit(5); }
    const suffix = new Date().toISOString().replace(/[-:]/g, "").slice(0, 15);
    const backupPath = `${authPath}.bak-${suffix}`;
    fs.copyFileSync(authPath, backupPath);
    const prev = (store.tokens || {}).operator || {};
    store.tokens = store.tokens || {};
    store.tokens.operator = {
      ...prev,
      token: auth.deviceToken,
      scopes: auth.scopes || prev.scopes || [],
      updatedAtMs: auth.issuedAtMs || Date.now()
    };
    fs.writeFileSync(authPath, JSON.stringify(store, null, 2) + "\n", { mode: 0o600 });
    console.log(`OK: device-auth.json operator token updated (backup: ${path.basename(backupPath)})`);
    ws.close();
    process.exit(0);
  }
});
ws.on("error", (e) => { console.log("FAIL:", e.message); process.exit(6); });
