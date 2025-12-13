# RaspberryPiMichael

All pieces for the GPIO button listener, Node web server, and Svelte wav player live in this repository so a single sync/update is enough.

## Layout
- `button.py`: listens to the GPIO button and broadcasts events over WebSocket on port 8080.
- `server.js`: serves the built UI from `rasp_wav_player/dist` and proxies WebSocket traffic to `PI_WS_URL` (default `ws://127.0.0.1:8080`).
- `rasp_wav_player/`: Svelte UI; `npm run build` produces the `dist` folder the server serves.
- `aos.sh`: helper script for the Pi to update the repo, install deps, start the Python listener + Node server, and launch Chromium.
- `logs/`: created by `aos.sh` for runtime logs (git-ignored).

## Usage
1. Install dependencies: `npm install` (runs the Svelte install automatically).
2. Build the UI: `npm run build` (root command builds `rasp_wav_player`).
3. Start the server: `npm start` (prestart rebuilds and serves on port 4173).
4. Kiosk flow on the Pi: run `./aos.sh` to update, install, start `button.py`, the server, and open Chromium at `http://localhost:4173`.

Set `PI_WS_URL` before `npm start` if the GPIO WebSocket runs on another host, e.g. `PI_WS_URL=ws://raspberrypi.local:8080 npm start`.
