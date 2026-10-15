<img src="Resources/AppIcon.png" width="96" alt="CF Recorder icon">

# CF Recorder

Simple native call recording for the Mac, with speaker separation and transcription, backed by Cloudflare and local models.

- **Speaker separation without guesswork.** Your mic and the other side of the call are recorded as two separate tracks, so every line is labeled by where it came from, not by a model guessing who's talking.
- **Live transcription on your Mac.** Apple's on-device `SpeechAnalyzer` transcribes both tracks as you talk, shown as a chat: you on the right, them on the left.
- **Notes and action items from a local model.** Ollama or Apple Intelligence writes a summary, decisions, action items, and open questions during the call and again when you stop.
- **Your calls anywhere, on your own Cloudflare.** Optional sync over standard OAuth sends each call to a small Cloudflare Worker (R2 + D1) where you can read and play them back from any browser. The Worker is in `web/`, and the API is documented so you can host your own.

Nothing leaves the Mac until you connect sync.

## Requirements

- macOS 26 (Tahoe) on Apple silicon
- Swift 6.2+ (the Command Line Tools are enough; Xcode isn't needed)
- [Ollama](https://ollama.com) with a model pulled, for notes. Defaults to `gemma4:12b-mlx`. Or switch Settings to Apple Intelligence.
- A headset. With speakers, the mic picks up the other person too and they show up on both sides.

## Build and run

```sh
make run       # build build/CF Recorder.app and open it
make install   # copy it to /Applications
```

`scripts/build-app.sh` builds the SwiftPM target, wraps it in a `.app` with `Resources/Info.plist`, and signs it with the first Developer ID or Apple Development identity in the keychain. Signing with a stable identity matters: macOS ties the mic and system audio permissions to the signature, and an ad-hoc build gets re-prompted on every rebuild. Set `CODESIGN_IDENTITY=-` to sign ad-hoc anyway.

On the first recording macOS asks for two permissions: **Microphone** and **System Audio Recording Only**. Both are under System Settings → Privacy & Security if you need to flip them later.

## Using it

- **⌘R** starts and stops a recording, from the window or the menu bar icon.
- Live, unfinished text shows as a dashed bubble with an orange `$`; it firms up when the recognizer finalizes the phrase.
- Type a title and the other person's name in the header. Both are saved with the call.
- Notes refresh about every 90 seconds during the call and once more when you stop. Click a checkbox to tick off an action item; the change saves to `notes.md`.

Settings (⌘,) holds your name, the default name for the other person, the notes engine, the Ollama host and model, audio devices, and sync.

### Audio sources

- **Your mic** follows the system default input unless you pick a device.
- **The guest** is desktop audio by default: everything the Mac plays, like a Zoom or Meet call in your headset. Turn that off to record the guest from a second input device instead, like a second mic for someone in the room. Each device gets its own engine, so two mics record at once.

A device you picked that's unplugged stops the recording from starting rather than quietly recording the wrong mic. If either side sends no audio at all for four seconds, the header says so.

### Sync

Settings → Sync → Connect opens your browser to sign in and approve CF Recorder; the tokens stay in the Keychain. After that each call syncs a few seconds after it changes, the transcript syncs every 30 seconds during a call (audio goes up once you stop), and launching the app backfills anything missed. Only files whose SHA-256 differs from the server's copy are sent. The API is in `web/README.md` under `// SYNC_API`.

## Where calls go

Each call gets a folder in `~/Documents/CF Recorder/`:

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
cfr="/Applications/CF Recorder.app/Contents/MacOS/CFRecorder"

"$cfr" transcribe call.m4a > call.txt     # [mm:ss] text, one line per phrase
"$cfr" notes < transcript.md > notes.md   # uses the engine from Settings
"$cfr" notes --apple < transcript.md      # force Apple Intelligence
"$cfr" devices                            # input devices, uid<TAB>name
"$cfr" sync connect [url]                 # sign in through the browser
"$cfr" sync                               # push every call; one line per call
"$cfr" sync status | disconnect
```

`transcribe` runs the same pipeline the app uses, which makes it the quickest smoke test after a change.

## How it works

| Piece | File | Notes |
|---|---|---|
| Mic capture | `Audio/SystemAudioCapture.swift` (`MicCapture`) | `AVAudioEngine` tap on the default input. |
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
- **No `NavigationSplitView`.** It lays out at its content's ideal width and overflows smaller windows, clipping both edges. The root is a plain `HStack` of columns.
