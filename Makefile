APP      = BetterWM
VERSION ?= $(shell git describe --tags --always 2>/dev/null | sed 's/^v//')
BUILD    = .build/release
BUNDLE   = dist/$(APP).app
ZIP      = dist/$(APP)-$(VERSION).zip

.PHONY: build test bundle sign zip cask install run demo clean

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

cask: zip
	@sha=$$(shasum -a 256 $(ZIP) | cut -d' ' -f1); \
	sed -i '' -e 's/version "[^"]*"/version "$(VERSION)"/' \
	          -e 's/sha256 "[^"]*"/sha256 "'$$sha'"/' Casks/betterwm.rb; \
	echo "Updated Casks/betterwm.rb to $(VERSION) ($$sha)"

install: sign
	rm -rf /Applications/$(APP).app
	cp -R $(BUNDLE) /Applications/
	xattr -dr com.apple.quarantine /Applications/$(APP).app 2>/dev/null || true

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

# Records demo/demo.txt to dist/demo.mov (and demo.mp4 if ffmpeg is installed).
# Needs Screen Recording permission for the terminal. DEMO_SECONDS bounds the recording.
DEMO_SECONDS ?= 45
demo:
	swift build --product $(APP)
	mkdir -p dist
	rm -f dist/demo.mov dist/demo.mp4
	pkill -x $(APP) || true
	.build/debug/$(APP) --demo demo/demo.txt & pid=$$!; trap 'kill $$pid 2>/dev/null' INT TERM EXIT; sleep 1; \
	screencapture -v -V $(DEMO_SECONDS) -C dist/demo.mov; kill $$pid 2>/dev/null; trap - INT TERM EXIT
	@command -v ffmpeg >/dev/null && ffmpeg -y -loglevel error -i dist/demo.mov -vf "scale=1920:-2" -c:v libx264 -pix_fmt yuv420p -crf 20 dist/demo.mp4 && echo "Wrote dist/demo.mp4" || echo "Wrote dist/demo.mov (install ffmpeg for mp4)"
