VALKEY_7_VERSION = 7.2.11
VALKEY_8_VERSION = 8.1.4
VALKEY_9_VERSION = 9.0.0
STUNNEL_VERSION = 5.72

.DEFAULT_GOAL := targets
.PHONY: targets fetch add-blobs blobs clean dev

targets:
	@echo "Available targets:"
	@echo "  fetch      - Download all Valkey and stunnel tarballs"
	@echo "  add-blobs  - Add downloaded tarballs to BOSH blobs"
	@echo "  blobs      - fetch + add-blobs (complete workflow)"
	@echo "  dev        - Create development release tarball"
	@echo "  clean      - Remove downloaded tarballs and dev release"

fetch:
	@echo "Creating blobs directory..."
	@mkdir -p blobs
	@echo "Fetching Valkey 7 ($(VALKEY_7_VERSION))..."
	curl -sL "https://github.com/valkey-io/valkey/archive/refs/tags/$(VALKEY_7_VERSION).tar.gz" -o "blobs/valkey-$(VALKEY_7_VERSION).tar.gz"
	@echo "Fetching Valkey 8 ($(VALKEY_8_VERSION))..."
	curl -sL "https://github.com/valkey-io/valkey/archive/refs/tags/$(VALKEY_8_VERSION).tar.gz" -o "blobs/valkey-$(VALKEY_8_VERSION).tar.gz"
	@echo "Fetching Valkey 9 ($(VALKEY_9_VERSION))..."
	curl -sL "https://github.com/valkey-io/valkey/archive/refs/tags/$(VALKEY_9_VERSION).tar.gz" -o "blobs/valkey-$(VALKEY_9_VERSION).tar.gz"
	@echo "Fetching stunnel ($(STUNNEL_VERSION))..."
	curl -sL "https://www.stunnel.org/downloads/stunnel-$(STUNNEL_VERSION).tar.gz" -o "blobs/stunnel-$(STUNNEL_VERSION).tar.gz"
	@echo "All tarballs downloaded to blobs/"
	@ls -lh blobs/

add-blobs:
	@echo "Adding Valkey 7 blob..."
	bosh add-blob "blobs/valkey-$(VALKEY_7_VERSION).tar.gz" "valkey-$(VALKEY_7_VERSION).tar.gz"
	@echo "Adding Valkey 8 blob..."
	bosh add-blob "blobs/valkey-$(VALKEY_8_VERSION).tar.gz" "valkey-$(VALKEY_8_VERSION).tar.gz"
	@echo "Adding Valkey 9 blob..."
	bosh add-blob "blobs/valkey-$(VALKEY_9_VERSION).tar.gz" "valkey-$(VALKEY_9_VERSION).tar.gz"
	@echo "Adding stunnel blob..."
	bosh add-blob "blobs/stunnel-$(STUNNEL_VERSION).tar.gz" "stunnel-$(STUNNEL_VERSION).tar.gz"
	@echo "Current blobs:"
	bosh blobs

clean:
	@echo "Cleaning up blobs directory..."
	rm -rf blobs/
	@echo "Removing dev release tarball..."
	rm -f valkey-forge-dev.tar.gz
	@echo "Cleanup complete."

dev:
	@echo "Creating development release..."
	bosh create-release --force --tarball="$$PWD/valkey-forge-dev.tar.gz"
	@echo "Development release created: valkey-forge-dev.tar.gz"

blobs: fetch add-blobs
