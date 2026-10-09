LABEL     := com.hedworth.parakeet-ane
BIN_DIR   := $(HOME)/.local/bin
AGENT     := $(HOME)/Library/LaunchAgents/$(LABEL).plist
DOMAIN    := gui/$(shell id -u)

.PHONY: build test install uninstall restart logs

build:
	swift build -c release

test:
	swift test

# Copy the binary out of .build so `swift package clean` can't break the service.
install: build
	mkdir -p $(BIN_DIR)
	install -m 755 .build/release/parakeet-ane-server $(BIN_DIR)/parakeet-ane-server
	sed 's|__HOME__|$(HOME)|g' launchd/$(LABEL).plist > $(AGENT)
	-launchctl bootout $(DOMAIN)/$(LABEL) 2>/dev/null
	launchctl bootstrap $(DOMAIN) $(AGENT)
	@echo "Installed. Waiting for the model to load..."
	@for i in $$(seq 1 120); do curl -sf http://127.0.0.1:11435/health >/dev/null && echo "Ready on http://127.0.0.1:11435/v1" && exit 0; sleep 1; done; \
		echo "Not ready yet: see ~/Library/Logs/parakeet-ane-server.log"; exit 1

uninstall:
	-launchctl bootout $(DOMAIN)/$(LABEL)
	rm -f $(AGENT) $(BIN_DIR)/parakeet-ane-server

restart:
	launchctl kickstart -k $(DOMAIN)/$(LABEL)

logs:
	tail -f $(HOME)/Library/Logs/parakeet-ane-server.log
