import { mount } from "svelte";
import "./app.css";
import App from "./App.svelte";

// Forward browser console logs to backend for kiosk logging
type LogLevel = "log" | "info" | "warn" | "error";
const uiLogEndpoint = "/ui-log";

const originalConsole = {
  log: console.log,
  info: console.info,
  warn: console.warn,
  error: console.error,
};

const safeStringify = (value: unknown): string => {
  try {
    if (typeof value === "string") return value;
    return JSON.stringify(value);
  } catch (_err) {
    try {
      return String(value);
    } catch (_err2) {
      return "[unserializable]";
    }
  }
};

const sendUiLog = (level: LogLevel, args: unknown[]): void => {
  try {
    const payload = {
      level,
      ts: Date.now(),
      message: args.map(safeStringify).join(" "),
    };

    const body = JSON.stringify(payload);

    if (navigator.sendBeacon) {
      const blob = new Blob([body], { type: "application/json" });
      navigator.sendBeacon(uiLogEndpoint, blob);
      return;
    }

    void fetch(uiLogEndpoint, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body,
      keepalive: true,
    });
  } catch (err) {
    // Avoid recursive logging if this fails
    originalConsole.error?.("ui-log failed", err);
  }
};

(["log", "info", "warn", "error"] as LogLevel[]).forEach((level) => {
  const original = originalConsole[level];
  console[level] = (...args: unknown[]) => {
    original?.(...args);
    sendUiLog(level, args);
  };
});

const app = mount(App, {
  target: document.getElementById("app")!,
});

export default app;
