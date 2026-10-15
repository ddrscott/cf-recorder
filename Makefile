APP := build/Recorder.app

.PHONY: app run install release clean

app:
	scripts/build-app.sh

run: app
	open "$(APP)"

install: app
	rm -rf "/Applications/Recorder.app"
	cp -R "$(APP)" /Applications/
	@echo "Installed /Applications/Recorder.app"

# Signed, notarized, stapled, and installed: the build to actually use.
release:
	scripts/notarize.sh
	rm -rf "/Applications/Recorder.app"
	ditto "$(APP)" /Applications/Recorder.app
	@echo "Installed /Applications/Recorder.app (notarized)"

clean:
	rm -rf .build build
