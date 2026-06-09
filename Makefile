APP_NAME := Ebook Capture
BUNDLE_ID := com.kdmsnr.ebook-capture
EXECUTABLE_NAME := ebook-capture
APP_DIR := dist/$(APP_NAME).app
CONTENTS_DIR := $(APP_DIR)/Contents
MACOS_DIR := $(CONTENTS_DIR)/MacOS
RESOURCES_DIR := $(CONTENTS_DIR)/Resources
CODE_SIGN_REQUIREMENT := =designated => identifier "$(BUNDLE_ID)"

export SWIFTPM_HOME ?= $(CURDIR)/.build/swiftpm-home
export CLANG_MODULE_CACHE_PATH ?= $(CURDIR)/.build/clang-module-cache

.PHONY: app open build clean setup-signing

app: build
	@mkdir -p "$(MACOS_DIR)" "$(RESOURCES_DIR)"
	@install -m 755 "$$(swift build -c release --show-bin-path)/$(EXECUTABLE_NAME)" "$(MACOS_DIR)/$(EXECUTABLE_NAME)"
	@install -m 644 "Resources/AppIcon.icns" "$(RESOURCES_DIR)/AppIcon.icns"
	@{ \
		echo '<?xml version="1.0" encoding="UTF-8"?>'; \
		echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'; \
		echo '<plist version="1.0">'; \
		echo '<dict>'; \
		echo '  <key>CFBundleDevelopmentRegion</key>'; \
		echo '  <string>ja</string>'; \
		echo '  <key>CFBundleDisplayName</key>'; \
		echo '  <string>$(APP_NAME)</string>'; \
		echo '  <key>CFBundleExecutable</key>'; \
		echo '  <string>$(EXECUTABLE_NAME)</string>'; \
		echo '  <key>CFBundleIconFile</key>'; \
		echo '  <string>AppIcon</string>'; \
		echo '  <key>CFBundleIdentifier</key>'; \
		echo '  <string>$(BUNDLE_ID)</string>'; \
		echo '  <key>CFBundleInfoDictionaryVersion</key>'; \
		echo '  <string>6.0</string>'; \
		echo '  <key>CFBundleName</key>'; \
		echo '  <string>$(APP_NAME)</string>'; \
		echo '  <key>CFBundlePackageType</key>'; \
		echo '  <string>APPL</string>'; \
		echo '  <key>CFBundleShortVersionString</key>'; \
		echo '  <string>0.1.0</string>'; \
		echo '  <key>CFBundleVersion</key>'; \
		echo '  <string>1</string>'; \
		echo '  <key>LSMinimumSystemVersion</key>'; \
		echo '  <string>13.0</string>'; \
		echo '</dict>'; \
		echo '</plist>'; \
	} > "$(CONTENTS_DIR)/Info.plist"
	@codesign --force --sign - --requirements '$(CODE_SIGN_REQUIREMENT)' "$(APP_DIR)" >/dev/null
	@codesign -dv -r- "$(APP_DIR)" 2>&1 | grep 'designated =>' || true
	@echo 'Built $(CURDIR)/$(APP_DIR)'
	@echo
	@echo 'Open:'
	@echo '  open "$(CURDIR)/$(APP_DIR)"'
	@echo
	@echo 'Grant permissions to:'
	@echo '  $(APP_NAME).app'

build:
	@mkdir -p "$(SWIFTPM_HOME)" "$(CLANG_MODULE_CACHE_PATH)"
	swift build -c release

open: app
	open "$(APP_DIR)"

clean:
	rm -rf dist .build

setup-signing:
	@echo 'No setup needed. make app uses ad-hoc signing with a stable designated requirement:'
	@echo '  $(CODE_SIGN_REQUIREMENT)'
