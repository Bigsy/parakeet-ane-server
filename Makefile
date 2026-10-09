LABEL     := com.hedworth.parakeet-ane
BIN_DIR   := $(HOME)/.local/bin
AGENT_DIR := $(HOME)/Library/LaunchAgents
AGENT     := $(AGENT_DIR)/$(LABEL).plist
DOMAIN    := gui/$(shell id -u)

.PHONY: build test test-core consumer benchmark package install uninstall restart logs

build:
	swift build -c release

test:
	swift test

test-core:
	swift test --filter ParakeetCoreTests

consumer:
	swift run -c release --package-path Examples/CoreConsumer CoreConsumer

benchmark:
	python3 bench/generate.py
	swift build -c release --package-path bench

package: build
	./scripts/package-server.sh $(VERSION)

# Copy the binary out of .build so `swift package clean` can't break the service.
install: build
	mkdir -p "$(BIN_DIR)" "$(AGENT_DIR)" "$(HOME)/Library/Logs"
	install -m 755 .build/release/parakeet-ane-server "$(BIN_DIR)/parakeet-ane-server"
	@for bundle in .build/release/*.bundle; do [ ! -d "$$bundle" ] || cp -Rf "$$bundle" "$(BIN_DIR)/"; done
	cp launchd/$(LABEL).plist "$(AGENT)"
	/usr/libexec/PlistBuddy -c 'Set :ProgramArguments:0 $(BIN_DIR)/parakeet-ane-server' "$(AGENT)"
	/usr/libexec/PlistBuddy -c 'Set :StandardOutPath $(HOME)/Library/Logs/parakeet-ane-server.log' "$(AGENT)"
	/usr/libexec/PlistBuddy -c 'Set :StandardErrorPath $(HOME)/Library/Logs/parakeet-ane-server.log' "$(AGENT)"
	@# bootout returns before the job is gone; bootstrapping too early fails with error 5.
	@launchctl bootout $(DOMAIN)/$(LABEL) 2>/dev/null; \
		for i in $$(seq 1 50); do launchctl print $(DOMAIN)/$(LABEL) >/dev/null 2>&1 || break; sleep 0.1; done
	launchctl bootstrap $(DOMAIN) "$(AGENT)"
	@echo "Installed. Waiting for the model to load..."
	@for i in $$(seq 1 120); do curl -sf http://127.0.0.1:11435/health >/dev/null && echo "Ready on http://127.0.0.1:11435/v1" && exit 0; sleep 1; done; \
		echo "Not ready yet: see ~/Library/Logs/parakeet-ane-server.log"; exit 1

uninstall:
	-launchctl bootout $(DOMAIN)/$(LABEL)
	rm -f "$(AGENT)" "$(BIN_DIR)/parakeet-ane-server"

restart:
	launchctl kickstart -k $(DOMAIN)/$(LABEL)

logs:
	tail -f "$(HOME)/Library/Logs/parakeet-ane-server.log"
