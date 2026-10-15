APP      = BetterWM
VERSION ?= $(shell git describe --tags --always 2>/dev/null | sed 's/^v//')
BUILD    = .build/release
BUNDLE   = dist/$(APP).app
ZIP      = dist/$(APP)-$(VERSION).zip

.PHONY: build test bundle sign zip install run clean

build:
	swift build -c release --product BetterWM

test:
	swift run CoreTests

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

# Debug build as a bundle: needed for anything that reads Info.plist, such as Location Services.
run:
	swift build --product $(APP)
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS
	cp .build/debug/$(APP) $(BUNDLE)/Contents/MacOS/
	sed 's/VERSION/dev/g' Resources/Info.plist > $(BUNDLE)/Contents/Info.plist
	codesign --force --deep --sign - $(BUNDLE)
	pkill -x $(APP) || true
	$(BUNDLE)/Contents/MacOS/$(APP)

clean:
	rm -rf dist .build
