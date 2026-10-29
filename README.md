# XiaoZhi infra

Run your own XiaoZhi voice assistant: one ESP32 board talks to a server on your Mac, which answers through Claude. You can change its character (prompt, voice) and its faces on the OLED screen.

```
ESP32 board ──Wi-Fi──▶ xiaozhi server (Docker) ──▶ LiteLLM (Docker) ──▶ hai proxy (your Mac) ──▶ Claude
```

## Requirements

- A Mac (the Makefile uses macOS tools)
- [Docker Desktop](https://www.docker.com/products/docker-desktop/), running
- [`uv`](https://docs.astral.sh/uv/): `brew install uv`
- The `hai` proxy running on your Mac (port 6655), and your hai API key
- A `bread-compact-wifi` ESP32-S3 board with a 128×64 OLED, and a USB cable
- 2.4 GHz Wi-Fi that the board and your Mac share

## Quickstart

```sh
make setup        # creates .env, downloads the firmware source and the speech model (~900 MB)
```

Open `.env` and fill in `WIFI_SSID`, `WIFI_PASS`, `HAI_API_KEY` and `PORT`. For `PORT`, plug in the board and run `ls /dev/cu.usb*`.

```sh
make up           # start the server and LiteLLM
make chat         # check the LLM answers ("Hello, who are you?")
make build        # build the firmware in Docker (first time: large download, ~10 min)
make flash        # install it on the board over USB, with your Wi-Fi and server address
make logs         # watch the board connect
```

Wake the board (press its button) and talk to it.

## Change the character

Edit `prompt` (who the assistant is) and `TTS.EdgeTTS.voice` (how it sounds, e.g. `en-US-JennyNeural`, `en-GB-RyanNeural`) in `infra/data/.config.template.yaml`, then:

```sh
make update       # restarts the server; wake the board again afterwards
```

## Change the faces

The board shows a face for each emotion. The faces are the PNGs in `infra/faces/`, one per emotion:

```sh
# edit infra/faces/*.png, then check how they will look on the OLED:
make preview-faces
# put them on the board: bump FW_BUILD in the Makefile (e.g. 5 -> 6), then
make build
make deploy-ota   # the board installs it on its next boot (or: make flash)
```

**Image spec** (128×64 SSD1306 OLED):

| | |
|---|---|
| Size | **32 × 32 px** max. The face sits in a 32 px column left of the text, below the 16 px status bar |
| Colours | **Black = lit pixel, white or transparent = off.** The image is drawn over white, and every pixel with a blue value ≤ 135 lights up, so yellow, red and brown light up too. Use pure black and white |
| Format | PNG |
| Style | Bold shapes, lines at least 2 px wide. Fine detail disappears at this size |

**File names** must match the emotions exactly. A missing file falls back to the stock face. `neutral` is the idle face.

`neutral` · `happy` · `laughing` · `funny` · `sad` · `angry` · `crying` · `loving` · `embarrassed` · `surprised` · `shocked` · `thinking` · `winking` · `cool` · `relaxed` · `delicious` · `kissy` · `confident` · `sleepy` · `silly` · `confused`

The files in `infra/faces/` start as the stock faces (Google Noto Emoji, Apache-2.0), pixel-identical to what the board shows by default. Use them as templates. File names must be lowercase, without spaces: a file like `neutral copy.png` breaks the build.

## Commands

| Command | What it does |
|---|---|
| `make setup` | One-time: creates `.env` (generates the LiteLLM key, detects this Mac's IP), downloads the firmware source (pinned) and the speech model |
| `make up` / `make down` / `make logs` | Start, stop, or follow the server and LiteLLM |
| `make update` | Apply changes to the prompt, voice, keys or `infra/litellm.yaml` (restarts the server) |
| `make chat MSG="…"` | Send one message to the LLM directly, without board or server |
| `make build` | Build the firmware with your faces, in Docker. Version: `<firmware>.<FW_BUILD>` |
| `make flash` | USB: install the built firmware plus Wi-Fi and server address on the board |
| `make deploy-ota` | Over the air: the board installs the built firmware on its next boot |
| `make preview-faces` | Render `infra/faces/preview.png`, exactly as the OLED will show the faces |

**`FW_BUILD`** (in the Makefile) is your build number. Bump it for every build you deploy, so the board sees the new firmware as newer. `build`, `flash` and `deploy-ota` all use it.

## How it fits together

| File | Purpose |
|---|---|
| `.env` | Your settings and secrets (not committed). Template: `.env.example` |
| `infra/data/.config.template.yaml` | Server config: prompt, voice, LLM. `make up`/`update` render it into `.config.yaml`, filling in values from `.env` |
| `infra/litellm.yaml` | Which LLM the server's requests go to (via the hai proxy) |
| `infra/docker-compose.yml` | The server and LiteLLM containers |
| `infra/faces/` | Face images, compiled into the firmware by `make build` |
| `infra/patches/oled-faces.patch` | Firmware change so the OLED shows our face images instead of the built-in emoji font. Applied by `make build` |
| `infra/tools/` | Face tools: generates the compiled faces, renders the preview |
| `_repo/xiaozhi-esp32` | Firmware source, pinned to one commit so every laptop builds the same code |
| `infra/firmware/` | Build output: full image (`make flash`) and OTA image (`make deploy-ota`) |

## Troubleshooting

- **Check the server is up:** `curl http://<SERVER_IP>:8003/xiaozhi/ota/` should print the `ws://` address it hands to the board.
- **The board doesn't connect:** check `make logs`; check that `SERVER_IP` in `.env` is still your Mac's IP (it changes between networks), then run `make update` and `make flash`.
- **No answer, or an error from the LLM:** run `make chat`. If that fails, check that hai is running and `HAI_API_KEY` is set.
- **The board doesn't update over the air:** did you bump `FW_BUILD` before `make build`? The board only installs a newer version.
