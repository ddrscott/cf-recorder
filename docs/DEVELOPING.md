# Developing Recorder

The README covers what Recorder is for. This is how it's built, and what bit us along the way.

## Build and run

```sh
make run       # build build/Recorder.app and open it
make install   # copy it to /Applications
make release   # sign, notarize, staple, and install to /Applications
```

`scripts/build-app.sh` builds the SwiftPM target, wraps it in a `.app` with `Resources/Info.plist`, and signs it with the first Developer ID or Apple Development identity in the keychain. Signing with a stable identity matters: macOS ties the mic and system audio permissions to the signature, and an ad-hoc build gets re-prompted on every rebuild. Set `CODESIGN_IDENTITY=-` to sign ad-hoc anyway.

`make release` runs `scripts/notarize.sh`: it signs with Apple's secure timestamp (`TIMESTAMP=1`; everyday builds skip it so they work offline), zips the app with `ditto`, submits it with `notarytool --wait`, staples the ticket, and checks it with `spctl`. On a rejection it prints Apple's log. It needs a Developer ID Application identity and a notarytool keychain profile, `NOTARY_PROFILE` (default `maxpane-notary`, which holds the same team's credentials). A notarized build opens on any Mac without the Gatekeeper warning.

On the first recording macOS asks for two permissions: **Microphone** and **System Audio Recording Only**. Both are under System Settings → Privacy & Security if you need to flip them later.

## Using the app

- **⌘R** starts and stops a recording, from the window or the menu bar icon.
- Live, unfinished text shows as a dashed bubble with an orange `$`; it firms up when the recognizer finalizes the phrase.
- Type a title and the other person's name in the header. Both are saved with the call. Each time notes are written, the call gets a short title from them, unless you've typed your own.
- Notes refresh about every 90 seconds during the call and once more when you stop. Click a checkbox to tick off an action item; the change saves to `notes.md`.

Settings (⌘,) holds your name, the default name for the other person, the notes engine, the Ollama host and model, audio devices, and sync.

### Audio sources

- **Your mic** follows the system default input unless you pick a device.
- **The guest** is desktop audio by default: everything the Mac plays, like a Zoom or Meet call in your headset. Turn that off to record the guest from a second input device instead, like a second mic for someone in the room. Each device gets its own engine, so two mics record at once.

A device you picked that's unplugged stops the recording from starting rather than quietly recording the wrong mic. If either side sends no audio at all for four seconds, the header says so.

### Sync

Settings → Sync → Connect opens your browser to sign in and approve Recorder; the tokens stay in the Keychain. After that each call syncs a few seconds after it changes, the transcript syncs every 30 seconds during a call (audio goes up once you stop), and launching the app backfills anything missed. Only files whose SHA-256 differs from the server's copy are sent. The API is in `web/README.md` under `// SYNC_API`.

## Where calls go

Each call gets a folder in `~/Documents/Recorder/`:

```
2026-10-15 140312/
  me.m4a           your mic, AAC
  them.m4a         system audio, AAC
  meeting.json     transcript with timings, names, notes
  transcript.md    readable transcript
  notes.md         generated notes
```

## Command line

The app binary doubles as a CLI. Both commands read input and write to stdout.

```sh
cfr="/Applications/Recorder.app/Contents/MacOS/CFRecorder"

"$cfr" transcribe call.m4a > call.txt     # [mm:ss] text, one line per phrase
"$cfr" notes < transcript.md > notes.md   # uses the engine from Settings
"$cfr" notes --apple < transcript.md      # force Apple Intelligence
"$cfr" title < notes.md                   # a 3-7 word title, the one the app gives the call
"$cfr" devices                            # input devices, uid<TAB>name
open -n -W -a Recorder --args miccheck 8 [uid] --out /tmp/mic.txt   # buffers and peak per second, mic and desktop
open -n -W -a Recorder --args miccheck 15 --save /tmp/call --out /tmp/mic.txt   # plus m4a files and transcript
"$cfr" sync connect [url]                 # sign in through the browser
"$cfr" sync                               # push every call; one line per call
"$cfr" sync status | disconnect
```

`transcribe` runs the same pipeline the app uses, which makes it the quickest smoke test after a change. `miccheck` opens the mic and the desktop tap the way a call does. Run it through `open` so macOS checks Recorder's mic permission; launched from a terminal it gets the terminal's, and without that permission the mic reads as pure zeros.

## Code map

| Piece | File | Notes |
|---|---|---|
| Mic capture | `Audio/SystemAudioCapture.swift` (`MicCapture`) | `AVAudioEngine` tap on the default input, rebuilt on every config change. |
| System audio | `Audio/SystemAudioCapture.swift` | Core Audio process tap (`CATapDescription`, global, excluding this app) on a private aggregate device. No Screen Recording permission. |
| Per-stream pipeline | `Transcription/StreamTranscriber.swift` | Writes the m4a, converts to the recognizer's format, feeds `SpeechAnalyzer` + `SpeechTranscriber` with volatile results on. |
| Timeline | same | Each stream records its first buffer's offset from the session start, so both sides land on one clock and sort correctly. |
| Notes | `Notes/NotesGenerator.swift` | Streams from Ollama `/api/chat`, or from `FoundationModels`. The on-device model's context is small, so long calls are condensed in chunks first. |
| Devices | `Audio/AudioDevices.swift` | Input devices by Core Audio UID, which survives unplugging. `MicCapture(device:)` pins an engine to one. |
| Sync | `Sync/SyncClient.swift` | OAuth discovery, dynamic registration, PKCE with a loopback listener, Keychain, hash-skipping and multipart uploads. |
| State | `Model/AppModel.swift` | Orchestrates start/stop, live notes, autosave. Updates hop to main via `DispatchQueue.main` to keep volatile/final ordering intact. |

## Icon

`scripts/gen-icons.py` draws the icon (Signal Orange disc in a thin ring on `#1a1a1a`) and writes `Resources/AppIcon.icns` plus the web icons in `web/public/recordings/icons/`. The `.icns` art is masked to Apple's squircle at 824 of 1024 points so macOS 26 doesn't paint a pale rim around it.

## Gotchas we hit

- **Reserve the locale before downloading the speech model.** `AssetInventory.assetInstallationRequest(...).downloadAndInstall()` fails with a bare `_GenericObjCError 0` unless `AssetInventory.reserve(locale:)` ran first.
- **`AVAudioFile.read` throws at end of file** instead of returning zero frames. Loop on `framePosition < length`.
- **Bluetooth headsets stop `AVAudioEngine`.** Opening a headset's mic flips it from A2DP to the hands-free profile, and pinning any device reconfigures the engine too. The engine posts `AVAudioEngineConfigurationChange`, stops, and stays stopped, so the mic delivers nothing for the whole call. `MicCapture` restarts on every config change, and `StreamTranscriber` converts later buffers to the m4a's first format when the rate changes.
- **The tap's format lies about its sample rate.** `kAudioTapPropertyFormat` says 48 kHz, but the aggregate device runs on the output device's clock and delivers at that rate. A Bluetooth headset in hands-free mode runs at 16 kHz, so the guest got labeled 3x too fast and the recognizer returned nothing. `SystemAudioCapture` labels buffers with the aggregate's nominal rate, kept current by a property listener.
- **AAC rejects a fixed 64 kbps at 16 kHz.** The headset mic's file never opened. The m4a settings leave the bit rate to the encoder.
- **No `NavigationSplitView`.** It lays out at its content's ideal width and overflows smaller windows, clipping both edges. The root is a plain `HStack` of columns.
