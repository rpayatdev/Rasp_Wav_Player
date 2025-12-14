import asyncio
import lgpio
import os
import signal
import subprocess
import time

BUTTON_PIN = 27

# Tunables (edit here or via environment variables)
POLL_INTERVAL = float(os.environ.get("POLL_INTERVAL", "0.001"))  # seconds (1 ms)
DEBOUNCE_TIME = float(os.environ.get("DEBOUNCE_TIME", "0.03"))   # seconds (30 ms)
WS_VERBOSE = os.environ.get("WS_VERBOSE", "0") == "1"            # log every send

chip = lgpio.gpiochip_open(0)
lgpio.gpio_claim_input(chip, BUTTON_PIN, lgpio.SET_PULL_UP)

clients = set()

# ---------- timestamp helpers ----------
T0_NS = time.time_ns()
M0_NS = time.monotonic_ns()

def ts():
    """
    Wall clock ISO-ish with ms + monotonic ms since start for stable measurement.
    """
    now_ns = time.time_ns()
    mono_ns = time.monotonic_ns()
    wall_ms = now_ns // 1_000_000
    mono_ms = (mono_ns - M0_NS) / 1_000_000.0
    return f"[wall_ms={wall_ms} mono_ms={mono_ms:10.3f}]"

def log(msg: str):
    print(f"{ts()} {msg}", flush=True)

# ---------- websocket send ----------
async def send_safe(ws, msg: str):
    start_ns = time.monotonic_ns()
    try:
        if WS_VERBOSE:
            log(f"WS SEND start -> {msg}")
        await ws.send(msg)
        dur_ms = (time.monotonic_ns() - start_ns) / 1_000_000.0
        if WS_VERBOSE:
            log(f"WS SEND done  -> {msg} (dur_ms={dur_ms:.3f})")
    except Exception as e:
        dur_ms = (time.monotonic_ns() - start_ns) / 1_000_000.0
        log(f"WS SEND fail  -> {msg} (dur_ms={dur_ms:.3f}) err={repr(e)}; removing client")
        try:
            clients.remove(ws)
        except KeyError:
            pass

# ---------- button loop ----------
async def button_task():
    loop = asyncio.get_running_loop()

    raw_value = lgpio.gpio_read(chip, BUTTON_PIN)
    stable_value = raw_value
    last_change_time = loop.time()

    log(f"Button task gestartet. Initial raw={raw_value} stable={stable_value} (PULL_UP: press=0, release=1)")

    while True:
        now = loop.time()
        value = lgpio.gpio_read(chip, BUTTON_PIN)

        # raw change detected
        if value != raw_value:
            raw_value = value
            last_change_time = now
            log(f"GPIO raw change -> raw={raw_value} (debouncing...)")
        else:
            # stable edge after debounce time
            if value != stable_value and (now - last_change_time) >= DEBOUNCE_TIME:
                prev = stable_value
                stable_value = value

                edge = f"{prev}->{stable_value}"
                log(f"GPIO debounced edge -> {edge}")

                # With SET_PULL_UP: 1 means not pressed, 0 means pressed
                # PRESS start = falling edge 1 -> 0
                if prev == 1 and stable_value == 0:
                    log("BUTTON PRESS (start) -> sende DOWN")
                    if clients:
                        msg = "DOWN"
                        await asyncio.gather(
                            *[send_safe(ws, msg) for ws in list(clients)],
                            return_exceptions=True
                        )
                    else:
                        log("No WS clients connected; skipping send")

                # Optional: also log release
                elif prev == 0 and stable_value == 1:
                    log("BUTTON RELEASE (end)")

        await asyncio.sleep(POLL_INTERVAL)

async def main():
    import websockets

    stop = asyncio.Future()

    async def ws_handler(websocket):
        clients.add(websocket)
        addr = getattr(websocket, "remote_address", None)
        log(f"WS client connected: {addr} (clients={len(clients)})")
        try:
            async for msg in websocket:
                log(f"WS RECV <- {msg} from {addr}")

                if msg == "EXIT":
                    log("EXIT erhalten, beende chromium und server")
                    try:
                        subprocess.run(["pkill", "chromium-browser"], check=False)
                        log("pkill chromium-browser issued")
                    except Exception as e:
                        log(f"pkill failed: {repr(e)}")

                    if not stop.done():
                        stop.set_result(True)

        finally:
            addr = getattr(websocket, "remote_address", None)
            if websocket in clients:
                clients.remove(websocket)
            log(f"WS client disconnected: {addr} (clients={len(clients)})")

    server = await websockets.serve(
        ws_handler,
        "0.0.0.0",
        8080,
        compression=None,   # no per-message deflate to cut latency
        max_queue=1,        # drop backlog quickly
        ping_interval=20,
        ping_timeout=20,
    )
    log("WebSocket Server gestartet auf 0.0.0.0:8080")

    btn_task = asyncio.create_task(button_task())

    def _stop_signal(*_):
        log("Stop-Signal erhalten")
        if not stop.done():
            stop.set_result(True)

    loop = asyncio.get_running_loop()
    loop.add_signal_handler(signal.SIGINT, _stop_signal)
    loop.add_signal_handler(signal.SIGTERM, _stop_signal)

    await stop
    log("Stop erhalten, fahre runter")

    btn_task.cancel()
    await asyncio.gather(btn_task, return_exceptions=True)
    server.close()
    await server.wait_closed()
    log("Server closed")

if __name__ == "__main__":
    try:
        asyncio.run(main())
    finally:
        log("GPIO Chip schliessen")
        try:
            lgpio.gpiochip_close(chip)
        except Exception as e:
            log(f"GPIO close error: {repr(e)}")
