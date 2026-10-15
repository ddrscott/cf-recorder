APP := build/Recorder.app

.PHONY: app run install clean

app:
	scripts/build-app.sh

run: app
	open "$(APP)"

install: app
	rm -rf "/Applications/Recorder.app"
	cp -R "$(APP)" /Applications/
	@echo "Installed /Applications/Recorder.app"

clean:
	rm -rf .build build
