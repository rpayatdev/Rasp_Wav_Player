import express from "express";
import path from "path";
import fs from "fs";
import { fileURLToPath } from "url";
import http from "http";
import { WebSocketServer, WebSocket } from "ws";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const LOG_DIR = path.join(__dirname, "logs");
const UI_LOG_FILE = path.join(LOG_DIR, "ui.log");

const app = express();
const PORT = 4173;
const DIST_DIR = path.join(__dirname, "rasp_wav_player", "dist");

// ensure log directory exists
try {
  fs.mkdirSync(LOG_DIR, { recursive: true });
} catch (err) {
  console.error("Failed to create log dir", err);
}

// accept JSON for UI log endpoint
app.use(express.json({ limit: "200kb" }));

// ---- timestamp helpers ----
const t0 = process.hrtime.bigint();
function ts() {
  const wallMs = Date.now();
  const monoMs = Number((process.hrtime.bigint() - t0) / 1000000n);
  return `[wall_ms=${wallMs} mono_ms=${monoMs.toString().padStart(8, " ")}]`;
}
function log(msg) {
  console.log(`${ts()} ${msg}`);
}

// ---- HTTP logging ----
app.use((req, res, next) => {
  const start = process.hrtime.bigint();
  log(`HTTP -> ${req.method} ${req.url}`);
  res.on("finish", () => {
    const durMs = Number((process.hrtime.bigint() - start) / 1000000n);
    log(`HTTP <- ${req.method} ${req.url} ${res.statusCode} (dur_ms=${durMs})`);
  });
  next();
});

if (!fs.existsSync(DIST_DIR)) {
  log(
    `WARN static bundle missing at ${DIST_DIR}. Run "npm run build" before starting the server.`,
  );
}

app.use(
  express.static(DIST_DIR, {
    setHeaders(res, filePath) {
      if (/\.(html|js|css|json|svg|txt|map)$/i.test(filePath)) {
        const type = res.getHeader("Content-Type");
        if (type && !String(type).toLowerCase().includes("charset")) {
          res.setHeader("Content-Type", `${type}; charset=utf-8`);
        }
      }
    },
  }),
);

app.get(/.*/, (req, res) => {
  res.setHeader("Content-Type", "text/html; charset=utf-8");
  res.sendFile(path.join(DIST_DIR, "index.html"));
});

// ---- UI console log sink ----
app.post("/ui-log", (req, res) => {
  const { level = "info", message = "", ts: clientTs } = req.body || {};
  const line = `[${new Date().toISOString()}] [${req.ip}] [${level}] ${String(
    clientTs ?? "",
  )} ${String(message)}\n`;

  fs.appendFile(UI_LOG_FILE, line, (err) => {
    if (err) log(`UI log append error: ${err.message}`);
  });

  res.sendStatus(204);
});

// Create one server for both HTTP + WS
const server = http.createServer(app);

// ---- Optional WS proxy ----
// Set PI_WS_URL to the python websocket endpoint
// Example: PI_WS_URL=ws://raspberrypi.local:8080
const PI_WS_URL = process.env.PI_WS_URL || "ws://127.0.0.1:8080";

const wss = new WebSocketServer({ server, path: "/ws" });

wss.on("connection", (clientWs, req) => {
  log(`WS(client) connected from ${req.socket.remoteAddress}`);

  const upstream = new WebSocket(PI_WS_URL);

  upstream.on("open", () => {
    log(`WS(upstream) connected -> ${PI_WS_URL}`);
  });

  upstream.on("message", (data) => {
    const msg = data.toString();
    log(`WS RECV <- upstream: ${msg}`);
    if (clientWs.readyState === WebSocket.OPEN) {
      clientWs.send(msg);
      log(`WS SEND -> client: ${msg}`);
    }
  });

  upstream.on("close", (code, reason) => {
    log(`WS(upstream) closed code=${code} reason=${reason?.toString?.() || ""}`);
    if (clientWs.readyState === WebSocket.OPEN) clientWs.close();
  });

  upstream.on("error", (err) => {
    log(`WS(upstream) error: ${err?.stack || err}`);
    if (clientWs.readyState === WebSocket.OPEN) clientWs.close();
  });

  clientWs.on("message", (data) => {
    const msg = data.toString();
    log(`WS RECV <- client: ${msg}`);
    if (upstream.readyState === WebSocket.OPEN) {
      upstream.send(msg);
      log(`WS SEND -> upstream: ${msg}`);
    } else {
      log(`WS DROP -> upstream not open (state=${upstream.readyState}) msg=${msg}`);
    }
  });

  clientWs.on("close", (code, reason) => {
    log(`WS(client) closed code=${code} reason=${reason?.toString?.() || ""}`);
    try { upstream.close(); } catch {}
  });

  clientWs.on("error", (err) => {
    log(`WS(client) error: ${err?.stack || err}`);
    try { upstream.close(); } catch {}
  });
});

server.listen(PORT, () => {
  log(`Server listening at http://localhost:${PORT}`);
  log(`WS proxy listening at ws://localhost:${PORT}/ws  -> upstream ${PI_WS_URL}`);
});
