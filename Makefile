APP := build/SpaceNamer.app
INSTALL_DIR ?= /Applications

# Command Line Tools ship swift-testing outside the default search path.
CLT_FRAMEWORKS := /Library/Developer/CommandLineTools/Library/Developer/Frameworks
TEST_FLAGS := $(if $(wildcard $(CLT_FRAMEWORKS)/Testing.framework),-Xswiftc -F$(CLT_FRAMEWORKS) -Xlinker -F$(CLT_FRAMEWORKS) -Xlinker -rpath -Xlinker $(CLT_FRAMEWORKS),)

.PHONY: app debug test run install uninstall signing clean

app:
	@scripts/build-app.sh

debug:
	@CONFIGURATION=debug ARCHS="$$(uname -m)" scripts/build-app.sh

test:
	swift test $(TEST_FLAGS)

run: app
	@pkill -x SpaceNamer 2>/dev/null || true
	@open $(APP)

install: app
	@pkill -x SpaceNamer 2>/dev/null || true
	@rm -rf "$(INSTALL_DIR)/SpaceNamer.app"
	@cp -R $(APP) "$(INSTALL_DIR)/"
	@open "$(INSTALL_DIR)/SpaceNamer.app"
	@echo "✓ Installed to $(INSTALL_DIR)/SpaceNamer.app"

uninstall:
	@pkill -x SpaceNamer 2>/dev/null || true
	@rm -rf "$(INSTALL_DIR)/SpaceNamer.app"
	@echo "✓ Removed $(INSTALL_DIR)/SpaceNamer.app (settings remain in ~/Library/Preferences/com.alexandercollins.SpaceNamer.plist)"

signing:
	@scripts/setup-signing.sh

clean:
	rm -rf .build build
