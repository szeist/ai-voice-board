# Local settings and secrets (make setup creates .env from .env.example)
-include .env
SERVER_OTA_PORT ?= 8003
OTA_URL   := http://$(SERVER_IP):$(SERVER_OTA_PORT)/xiaozhi/ota/
COMPOSE   := docker compose --env-file .env -f infra/docker-compose.yml

# LiteLLM proxy from compose (upstream configured in infra/litellm.yaml)
LLM_URL   ?= http://localhost:4000/v1
LLM_MODEL ?= claude-sonnet-4-6
LLM_KEY   ?= $(LITELLM_MASTER_KEY)
MSG       ?= Hello, who are you?

# Firmware source, pinned so every laptop builds the same code (and the faces patch applies)
FW_REPO   := _repo/xiaozhi-esp32
FW_COMMIT := 6b2990b9703d98384e541f805c39ac8da2e16d8d

# ASR model the server needs (not in the Docker image)
MODEL     := infra/models/SenseVoiceSmall/model.pt
MODEL_URL := https://modelscope.cn/models/iic/SenseVoiceSmall/resolve/master/model.pt

# One-time setup: .env (generated LiteLLM key, this Mac's IP), firmware source, ASR model
setup: clone $(MODEL)
	@if [ ! -f .env ]; then \
	  cp .env.example .env; \
	  sed -i '' "s|^LITELLM_MASTER_KEY=.*|LITELLM_MASTER_KEY=sk-$$(openssl rand -hex 24)|" .env; \
	  sed -i '' "s|^SERVER_IP=.*|SERVER_IP=$$(ipconfig getifaddr en0 || ipconfig getifaddr en1)|" .env; \
	  echo "Created .env. Now fill in WIFI_SSID, WIFI_PASS and HAI_API_KEY, then: make up"; \
	else echo ".env exists, left unchanged"; fi

$(MODEL):
	mkdir -p $(dir $(MODEL))
	curl -fL --retry 3 --progress-bar -o $@.part $(MODEL_URL) && mv $@.part $@

clone:
	@[ -d $(FW_REPO)/.git ] || { git init -q $(FW_REPO) && \
	  git -C $(FW_REPO) fetch -q --depth 1 https://github.com/78/xiaozhi-esp32.git $(FW_COMMIT) && \
	  git -C $(FW_REPO) checkout -q FETCH_HEAD && echo "Cloned firmware $(FW_COMMIT)"; }

# Render the server config from its template with values from .env
SERVER_CONFIG := infra/data/.config.yaml
config:
	@test -n "$(SERVER_IP)" -a -n "$(LITELLM_MASTER_KEY)" || { echo "Set SERVER_IP and LITELLM_MASTER_KEY in .env (run make setup)"; exit 1; }
	@{ echo "# Generated from .config.template.yaml by make config. Do not edit."; \
	  sed -e '/^# @template/d' -e 's|$${SERVER_IP}|$(SERVER_IP)|g' -e 's|$${SERVER_OTA_PORT}|$(SERVER_OTA_PORT)|g' \
	  -e 's|$${LITELLM_MASTER_KEY}|$(LITELLM_MASTER_KEY)|g' $(SERVER_CONFIG:.yaml=.template.yaml); } > $(SERVER_CONFIG)
	@echo "Rendered $(SERVER_CONFIG)"

up: config $(MODEL) ; $(COMPOSE) up -d
logs:  ; $(COMPOSE) logs -f
down:  ; $(COMPOSE) down

# Apply config changes (prompt, voice, keys, litellm.yaml): restart the server.
# The board drops its session on restart: wake it again.
update: config
	$(COMPOSE) up -d
	$(COMPOSE) restart xiaozhi litellm
	@echo "Server restarted with current config. Wake the board to reconnect."

chat:
	@jq -n --arg m "$(LLM_MODEL)" --arg c "$(MSG)" '{model: $$m, messages: [{role: "user", content: $$c}]}' \
	| curl -sS "$(LLM_URL)/chat/completions" -H "Authorization: Bearer $(LLM_KEY)" -H "Content-Type: application/json" -d @- \
	| jq -r '.choices[0].message.content // .'

# Our firmware: versioned <firmware version>.<FW_BUILD> (e.g. 2.5.3.1).
# Versions must stay dot-separated integers: boards ignore anything else.
# Bump FW_BUILD here for every build you deploy, so the board sees it as newer
# (build, flash and deploy-ota all use it).
FW_BUILD   ?= 5
FW_TYPE    ?= bread-compact-wifi          # board dir in main/boards/ (= OTA model name)
FW_BOARD   ?= bread-compact-wifi-128x64   # build variant (OLED size)
IDF_IMAGE  ?= espressif/idf:release-v6.1  # same image as upstream CI
FW_VERSION := $(shell git -C $(FW_REPO) show HEAD:CMakeLists.txt 2>/dev/null | sed -n 's/^set(PROJECT_VER "\(.*\)")/\1/p').$(FW_BUILD)
# Full flash image (USB) and app-only image (OTA)
FW_IMAGE   := infra/firmware/$(strip $(FW_BOARD))_$(FW_VERSION).bin
FW_OTA     := infra/firmware/$(strip $(FW_TYPE))_$(FW_VERSION).ota.bin

# Firmware patch: the OLED shows our face images (infra/faces/) instead of the built-in
# emoji font. Applied to _repo/xiaozhi-esp32 by make build; safe to re-run.
FACES_PATCH := $(CURDIR)/infra/patches/oled-faces.patch
patch-faces: clone
	@git -C $(FW_REPO) apply --reverse --check "$(FACES_PATCH)" 2>/dev/null || \
	  { git -C $(FW_REPO) apply "$(FACES_PATCH)" && echo "Applied oled-faces.patch"; }

# Build in Docker -> full image + OTA file in infra/firmware/.
# infra/faces/*.png are compiled into the app (oled_faces.h), so both make flash and
# make deploy-ota deliver them.
FACES ?= infra/faces
build: patch-faces
	uv run -q infra/tools/gen_oled_faces.py $(FACES) $(FW_REPO)/main/display/oled_faces.h
	sed -i '' 's/^set(PROJECT_VER ".*")/set(PROJECT_VER "$(FW_VERSION)")/' $(FW_REPO)/CMakeLists.txt
	docker run --rm --name xiaozhi-fw-build -v "$(CURDIR)/$(FW_REPO):/project" -w /project $(strip $(IDF_IMAGE)) \
	  bash -c 'source $$IDF_PATH/export.sh && python scripts/build.py $(strip $(FW_TYPE)) --name $(strip $(FW_BOARD))'; \
	  status=$$?; git -C $(FW_REPO) checkout CMakeLists.txt; exit $$status
	mkdir -p infra/firmware
	cp $(FW_REPO)/build/merged-binary.bin $(FW_IMAGE)
	cp $(FW_REPO)/build/xiaozhi.bin $(FW_OTA)
	@echo "Built $(FW_VERSION): $(FW_IMAGE) (flash), $(FW_OTA) (deploy-ota)"

# Over the air: the server offers it to the board if it's newer; installed on next boot
deploy-ota:
	@test -f $(FW_OTA) || { echo "$(FW_OTA) not found, run make build"; exit 1; }
	cp $(FW_OTA) infra/data/bin/$(strip $(FW_TYPE))_$(FW_VERSION).bin
	@echo "Deployed $(FW_VERSION). The board updates on its next boot."

# USB: our firmware + Wi-Fi + OTA URL (new board, or re-provision)
flash:
	@test -n "$(SERVER_IP)" -a -n "$(WIFI_SSID)" -a -n "$(PORT)" || { echo "Set SERVER_IP, WIFI_SSID, WIFI_PASS and PORT in .env (see .env.example)"; exit 1; }
	@test -f $(FW_IMAGE) || { echo "$(FW_IMAGE) not found, run make build"; exit 1; }
	uvx esptool --port $(PORT) --after no-reset write-flash 0x0 $(FW_IMAGE)
	printf 'key,type,encoding,value\nwifi,namespace,,\nssid,data,string,$(WIFI_SSID)\npassword,data,string,$(WIFI_PASS)\nota_url,data,string,$(OTA_URL)\n' > nvs.csv
	uvx --from esp-idf-nvs-partition-gen python -m esp_idf_nvs_partition_gen generate nvs.csv nvs.bin 0x4000
	uvx esptool --port $(PORT) write-flash 0x9000 nvs.bin
	rm nvs.csv nvs.bin

# Preview of the faces exactly as the patched OLED shows them (pixel on/off rule of the panel,
# font fallback for missing images). Not put on the board.
FACES_PREVIEW := $(FACES)/preview.png
preview-faces:
	@test -d $(FW_REPO)/managed_components/78__xiaozhi-fonts || { echo "Run make build once first (downloads the emoji font)"; exit 1; }
	uv run -q infra/tools/preview_faces.py $(FACES) $(FW_REPO)/managed_components/78__xiaozhi-fonts $(FACES_PREVIEW)
	open $(FACES_PREVIEW)
