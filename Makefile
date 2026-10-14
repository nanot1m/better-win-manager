APP      = BetterWM
VERSION ?= $(shell git describe --tags --always 2>/dev/null | sed 's/^v//')
BUILD    = .build/release
BUNDLE   = dist/$(APP).app
ZIP      = dist/$(APP)-$(VERSION).zip

.PHONY: build bundle sign zip install clean

build:
	swift build -c release

bundle: build
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS
	cp $(BUILD)/$(APP) $(BUNDLE)/Contents/MacOS/
	sed 's/VERSION/$(VERSION)/g' Resources/Info.plist > $(BUNDLE)/Contents/Info.plist

# Ad-hoc signature: free, but Gatekeeper still warns on download and the identity changes per build.
sign: bundle
	codesign --force --deep --sign - $(BUNDLE)
	codesign --verify --verbose=2 $(BUNDLE)

zip: sign
	rm -f $(ZIP)
	ditto -c -k --keepParent $(BUNDLE) $(ZIP)
	@echo "Built $(ZIP)"

install: sign
	rm -rf /Applications/$(APP).app
	cp -R $(BUNDLE) /Applications/

clean:
	rm -rf dist .build
