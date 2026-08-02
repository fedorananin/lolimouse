# LoLiMouse — build, bundle, sign, install.
#
# The important target is `make install`. Everything else exists to support it.
#
# Signing note: macOS ties Accessibility and Input Monitoring grants to an app's
# code signature. An ad-hoc signature changes on every rebuild, so the system
# treats each build as a brand new app and asks for the permissions again. To
# avoid that, create a free self-signed certificate once (`make signing-help`)
# and point LOLIMOUSE_SIGN_IDENTITY at it — no Apple Developer account needed.

-include .signing.mk

APP_NAME     := LoLiMouse
BUNDLE_ID    := me.fedorananin.LoLiMouse
CONFIG       := release
BUILD_DIR    := .build/$(CONFIG)
BUNDLE       := build/$(APP_NAME).app
CONTENTS     := $(BUNDLE)/Contents
INSTALL_DIR  := /Applications

# Marketing version stamped into the bundle, e.g. `make bundle VERSION=0.1.0`.
# Empty keeps whatever Resources/Info.plist says. The release workflow passes
# the tag here so the app always reports the version it was released as.
VERSION      ?=

# UNIVERSAL=1 builds a fat arm64 + x86_64 binary. Used by the release workflow;
# a local `make install` builds the host architecture only, which is faster.
ifeq ($(UNIVERSAL),1)
BUILD_FLAGS  := --arch arm64 --arch x86_64
BUILD_DIR    := .build/apple/Products/Release
endif

# Signing identity: a name, or a SHA-1 fingerprint.
#
# A fingerprint is worth knowing about. A self-signed certificate that has no
# trust settings does not appear in `security find-identity -v -p codesigning`,
# so codesign cannot find it by name — but it signs perfectly well when given
# its fingerprint. That avoids having to add trust settings at all.
#
#   security find-identity | grep 'Code Signing\|Local'
SIGN_IDENTITY ?= $(LOLIMOUSE_SIGN_IDENTITY)

.PHONY: all build bundle sign install uninstall run clean test lint signing-help icon release-zip

all: bundle

build:
	swift build -c $(CONFIG) $(BUILD_FLAGS)

bundle: build icon
	@rm -rf "$(BUNDLE)"
	@mkdir -p "$(CONTENTS)/MacOS" "$(CONTENTS)/Resources"
	@cp "$(BUILD_DIR)/$(APP_NAME)" "$(CONTENTS)/MacOS/$(APP_NAME)"
	@cp Resources/Info.plist "$(CONTENTS)/Info.plist"
ifneq ($(strip $(VERSION)),)
	@/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" "$(CONTENTS)/Info.plist"
	@/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(VERSION)" "$(CONTENTS)/Info.plist"
endif
	@cp Resources/AppIcon.icns "$(CONTENTS)/Resources/AppIcon.icns" 2>/dev/null || true
	@printf 'APPL????' > "$(CONTENTS)/PkgInfo"
	@$(MAKE) --no-print-directory sign
	@echo "==> built $(BUNDLE)"

# What the release workflow publishes: a zip that preserves the signature.
release-zip: bundle
	@ditto -c -k --keepParent "$(BUNDLE)" "build/$(APP_NAME).zip"
	@echo "==> built build/$(APP_NAME).zip"

icon:
	@test -f Resources/AppIcon.icns || swift Scripts/make-icon.swift Resources/AppIcon.icns

sign:
ifeq ($(strip $(SIGN_IDENTITY)),)
	@echo "==> signing ad-hoc (permissions will reset on every rebuild — see 'make signing-help')"
	@codesign --force --sign - --identifier "$(BUNDLE_ID)" "$(BUNDLE)"
else
	@echo "==> signing with $(SIGN_IDENTITY)"
	@codesign --force --identifier "$(BUNDLE_ID)" --sign "$(SIGN_IDENTITY)" "$(BUNDLE)"
endif
	@codesign --verify --verbose=1 "$(BUNDLE)" 2>&1 | sed 's/^/    /'

install: bundle
	@echo "==> installing to $(INSTALL_DIR)"
	@osascript -e 'quit app "$(APP_NAME)"' 2>/dev/null || true
	@sleep 1
	@rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	@cp -R "$(BUNDLE)" "$(INSTALL_DIR)/"
	@xattr -dr com.apple.quarantine "$(INSTALL_DIR)/$(APP_NAME).app" 2>/dev/null || true
	@echo "==> installed. Open it with: open -a $(APP_NAME)"

uninstall:
	@osascript -e 'quit app "$(APP_NAME)"' 2>/dev/null || true
	@rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	@echo "==> removed $(INSTALL_DIR)/$(APP_NAME).app"
	@echo "    Settings remain at ~/Library/Application Support/LoLiMouse"

run: bundle
	@open "$(BUNDLE)"

test:
	swift run LoLiMouseTests

clean:
	swift package clean
	rm -rf build

signing-help:
	@echo ""
	@echo "  Keeping macOS permissions across rebuilds"
	@echo "  ----------------------------------------"
	@echo "  1. Open Keychain Access."
	@echo "  2. Menu: Keychain Access > Certificate Assistant > Create a Certificate…"
	@echo "  3. Name:            LoLiMouse Self-Signed"
	@echo "     Identity type:   Self Signed Root"
	@echo "     Certificate type: Code Signing"
	@echo "  4. Create it, then build with:"
	@echo ""
	@echo "       LOLIMOUSE_SIGN_IDENTITY='LoLiMouse Self-Signed' make install"
	@echo ""
	@echo "  The signature then stays stable, so Accessibility and Input Monitoring"
	@echo "  only have to be granted once. No Apple Developer account is involved."
	@echo ""
