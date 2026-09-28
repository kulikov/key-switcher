.DEFAULT_GOAL := build

.PHONY: build install run clean

build: build/AppIcon.icns
	mkdir -p "build/Key Switcher.app/Contents/MacOS" "build/Key Switcher.app/Contents/Resources" build/module-cache
	xcrun swiftc main.swift -o "build/Key Switcher.app/Contents/MacOS/KeySwitcher" -O -module-cache-path build/module-cache
	cp Info.plist "build/Key Switcher.app/Contents/Info.plist"
	cp build/AppIcon.icns "build/Key Switcher.app/Contents/Resources/AppIcon.icns"
	codesign --force --sign "Apple Development" "build/Key Switcher.app"
	touch "build/Key Switcher.app"

build/AppIcon.icns: assets/app-icon.png
	mkdir -p build/AppIcon.iconset
	for size in 16 32 128 256 512; do \
		sips -z $$size $$size "$<" --out "build/AppIcon.iconset/icon_$${size}x$${size}.png" >/dev/null; \
		double=$$((size * 2)); \
		sips -z $$double $$double "$<" --out "build/AppIcon.iconset/icon_$${size}x$${size}@2x.png" >/dev/null; \
	done
	iconutil -c icns build/AppIcon.iconset -o "$@"

install: build
	-pkill -x KeySwitcher
	mkdir -p "$(HOME)/Applications"
	ditto "build/Key Switcher.app" "$(HOME)/Applications/Key Switcher.app"

run: install
	open "$(HOME)/Applications/Key Switcher.app"

clean:
	rm -rf build
