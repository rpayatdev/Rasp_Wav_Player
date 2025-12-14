# Raspberry Pi WAV Player

All pieces for the GPIO button listener, Node web server, and Svelte wav player live in this repository so a single sync/update is enough.

## Layout
- `button.py`: listens to the GPIO button and broadcasts events over WebSocket on port 8080.
- `server.js`: serves the built UI from `rasp_wav_player/dist` and proxies WebSocket traffic to `PI_WS_URL` (default `ws://127.0.0.1:8080`); also receives UI console logs at `/ui-log`.
- `rasp_wav_player/`: Svelte UI; `npm run build` produces the `dist` folder the server serves.
- `aos_setup.sh`: update/install/build helper; only installs/builds when `git pull` actually updates the repo.
- `aos.sh`: runtime launcher for the Pi; starts `button.py`, starts the Node server, waits for it to come up, then launches Chromium in kiosk mode to `http://localhost:4173`.
- `logs/`: created automatically; runtime logs land here.

## Prerequisites (on the Pi)
- Node.js + npm
- Python 3 for `button.py`
- Chromium installed and accessible as `chromium`

## One-time setup
Make the scripts executable (on Linux/Pi):
```sh
chmod +x aos_setup.sh aos.sh
```

Install everything (runs only when `git pull` changes HEAD):
```sh
./aos_setup.sh
```
This will:
- `git pull --rebase --autostash`
- `npm install` (root + Svelte UI)
- `npm run build` (Svelte UI -> `rasp_wav_player/dist`)

If there is no new commit or `git pull` fails (offline/local changes), the script logs it and skips install/build.

## Daily use (kiosk)
```sh
./aos.sh
```
This will:
- start `button.py` (GPIO listener) -> `logs/button.log`
- start the Node server on port 4173 -> `logs/aosjs.log`
- wait for the HTTP server to respond before opening the browser
- launch Chromium kiosk to `http://localhost:4173` -> `logs/chromium.log`

### Logging
- Backend/server: `logs/aosjs.log`
- Frontend console (from the kiosk UI): `logs/ui.log` (sent via `/ui-log`)
- GPIO listener: `logs/button.log`
- Chromium process/stdout: `logs/chromium.log`

## Manual development commands
- Install deps: `npm install`
- Build UI: `npm run build`
- Start server only (expects existing `dist`): `npm start` (serves `dist/` on port 4173)
- Override GPIO WebSocket target: `PI_WS_URL=ws://raspberrypi.local:8080 npm start`
