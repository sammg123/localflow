# LocalFlow

A private, fully local Wispr Flow replacement for macOS. Hold a key, speak, release: clean text lands in whatever app you're typing in. Nothing ever leaves your Mac.

Wispr Flow sends every word you dictate to its cloud (its own docs: "Transcription always occurs on the cloud"), routes text through 11 subprocessors, and costs $144/yr. LocalFlow does the same job on-device, faster, for free.

## How it works

```
hold hotkey ──► mic (16 kHz mono) ──► Parakeet TDT 0.6B v3 on the Neural Engine
                                        (or Apple SpeechAnalyzer)
release ──► rule cleanup (fillers, replacements, spoken commands)
       ──► Apple Intelligence on-device LLM polish (optional)
       ──► clipboard + simulated Cmd+V into the focused app (transcript stays on the clipboard)
```

- **ASR: NVIDIA Parakeet TDT 0.6B v3** via [FluidAudio](https://github.com/FluidInference/FluidAudio) (CoreML, runs on the Apple Neural Engine). Better English accuracy than Whisper large-v3-turbo, ~0.2-0.5s per utterance, ~500 MB one-time download, doesn't hallucinate on silence.
- **Alternative engine: Apple SpeechAnalyzer** (macOS 26). No download, model managed by the OS, runs out-of-process.
- **AI cleanup: Apple FoundationModels** (the Apple Intelligence on-device ~3B model). Removes fillers, applies self-corrections ("scratch that", "actually make that Wednesday"), formats lists, matches tone to the target app. Skipped for short utterances; falls back to rule-based cleanup if Apple Intelligence is off. Guarded: if the model answers your dictation instead of cleaning it, the raw transcript is used.
- **Insertion:** write transcript to the clipboard (marked concealed so clipboard managers don't archive it) → synthetic ⌘V. The transcript is left on the clipboard, so if a paste misses, ⌘V anywhere delivers it. If a password field (secure input) is active, nothing is pasted and you're told.

## Controls

| Gesture | Action |
|---|---|
| Hold hotkey (default: **Fn/🌐**) | Push-to-talk; release to transcribe |
| Double-tap hotkey | Hands-free with the live window (words appear as you talk); tap again to paste |
| **Ctrl + hotkey** (hold) | Command mode: select text first, then speak an edit ("make this shorter", "turn into bullets") — the selection is replaced |
| Esc while recording | Cancel |
| Menu bar → Paste Last Transcript | Recovery if a paste didn't land |

Command mode needs Apple Intelligence enabled (it's the edit engine) and isn't available when the main hotkey is ⌃⌥.

Hotkey options: Right ⌥ (default), Fn/🌐, Right ⌘, ⌃⌥. If you pick Fn, set System Settings → Keyboard → "Press 🌐 key to" = **Do Nothing** so macOS's own dictation stays out of the way.

Notes:
- Esc cancels the dictation but the keystroke also reaches the frontmost app (the hotkey listener is observe-only by design — it needs no Input Monitoring permission). Avoid Esc if the target app treats it destructively; a quick tap of the hotkey also cancels.
- Spoken "new line" / "new paragraph" commands are off by default (Settings → General) because they can misfire on dictation that legitimately contains those phrases. When on, they only trigger as standalone clauses.
- Hands-free recordings auto-stop at 5 minutes.

## Diagnostics

- `flow` in any terminal starts LocalFlow if it isn't running (`flow stop`, `flow restart`, `flow log`).
- `~/Library/Logs/LocalFlow.log` records each dictation's timing, mic device, peak level and paste result (never the words).
- The recorder rebuilds its audio engine on wake and input-device changes, and restarts capture once if audio stops arriving mid-recording.

## Build & install

```bash
cd ~/localflow
swift test          # unit tests (clipboard, live loop, audio stats, log, render)
./build.sh          # builds release, assembles ~/Applications/LocalFlow.app, signs
ln -sf ~/localflow/bin/flow ~/.local/bin/flow
open ~/Applications/LocalFlow.app
```

First run:
1. Grant **Microphone** when prompted.
2. Grant **Accessibility** (System Settings → Privacy & Security → Accessibility → enable LocalFlow). Needed to see the hotkey and to paste.
3. Wait for the one-time Parakeet model download (~500 MB, progress in the menu bar status).
4. For AI polish, Apple Intelligence must be enabled in System Settings.

**Ad-hoc signing caveat:** permissions are tied to the app's signature. After every rebuild you must re-toggle LocalFlow in Accessibility settings. If that gets old, create a free Apple Development certificate in Xcode and put its name in `build.sh`.

## Privacy posture

- No network calls except the one-time model downloads (FluidAudio's models from Hugging Face; Apple's models from Apple).
- Audio is held in memory only, never written to disk.
- Dictation history is in-memory by default (Settings → "Save history to disk" to opt in).
- Pasteboard entries are marked `org.nspasteboard.ConcealedType` so clipboard managers skip them.

## Feature parity vs Wispr Flow

| | Wispr Flow | LocalFlow |
|---|---|---|
| Where speech is processed | Their cloud (Baseten/AWS) | Your Mac |
| Hold-to-talk + hands-free | ✓ | ✓ |
| Filler removal, self-corrections | ✓ (cloud Llama) | ✓ (on-device Apple Intelligence) |
| Per-app tone | ✓ | ✓ (messaging/email/code categories) |
| Personal dictionary + replacements | ✓ | ✓ |
| History | ✓ (cloud sync optional) | ✓ (local, opt-in persistence) |
| Command mode ("edit selection by voice") | Pro only | ✓ (Ctrl+hotkey, on-device) |
| iPhone app | ✓ | no |
| Price | $12-15/mo | free |
