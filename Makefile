.PHONY: build test app install run clean

build:
	swift build

test:
	swift test

app:
	scripts/build-app.sh

install: app
	rm -rf /Applications/Roost.app
	cp -R build/Roost.app /Applications/
	@echo "Installed /Applications/Roost.app"

run: app
	open build/Roost.app

clean:
	rm -rf .build build
