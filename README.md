# LocalFlow

A private, fully local Wispr Flow replacement for macOS. Hold a key, speak, release: clean text lands in whatever app you're typing in. Nothing ever leaves your Mac.

Wispr Flow sends every word you dictate to its cloud (its own docs: "Transcription always occurs on the cloud"), routes text through 11 subprocessors, and costs $144/yr. LocalFlow does the same job on-device, faster, for free.

## How it works

```
hold hotkey ──► mic (16 kHz mono) ──► Parakeet TDT 0.6B v3 on the Neural Engine
                                        (or Apple SpeechAnalyzer)
release ──► rule cleanup (fillers, replacements, spoken commands)
       ──► Apple Intelligence on-device LLM polish (optional)
       ──► clipboard + simulated Cmd+V into the focused app (your clipboard is put back)
```

- **ASR: NVIDIA Parakeet TDT 0.6B v3** via [FluidAudio](https://github.com/FluidInference/FluidAudio) (CoreML, runs on the Apple Neural Engine). Better English accuracy than Whisper large-v3-turbo, ~0.2-0.5s per utterance, ~500 MB one-time download, doesn't hallucinate on silence.
- **Alternative engine: Apple SpeechAnalyzer** (macOS 26). No download, model managed by the OS, runs out-of-process.
- **AI cleanup: Apple FoundationModels** (the Apple Intelligence on-device ~3B model). Removes fillers, applies self-corrections ("scratch that", "actually make that Wednesday"), formats lists, matches tone to the target app. Skipped for short utterances; falls back to rule-based cleanup if Apple Intelligence is off. Guarded: if the model answers your dictation instead of cleaning it, the raw transcript is used.
- **Insertion:** save clipboard → write transcript (marked concealed so clipboard managers ignore it) → synthetic ⌘V → restore your clipboard (pastes run one at a time so overlapping ones can't swap clipboards). If a paste misses, tap **Control + hotkey** to paste the last transcript again. If a password field (secure input) is active, the text is left on the clipboard and you're told.

## Controls

| Gesture | Action |
|---|---|
| Hold hotkey (default: **Fn/🌐**) | Push-to-talk; release to transcribe |
| Double-tap hotkey | Hands-free window: words appear as you talk |
| Tap hotkey (hands-free) | Pause: the words are written down in the window, editable with the keyboard. Tap again to keep talking (new words go after your edits); hold to talk while held |
| Return or the ⏎ button (hands-free) | Paste the window's text into the app you were in. Shift+Return = new line |
| Esc or ✕ (hands-free) | Throw it away. The copy button next to ✕ copies what's in the window first |
| **Ctrl + hotkey** (tap) | Paste the last transcript again (your clipboard is untouched) |
| **Ctrl + hotkey** (hold) | Command mode: select text first, then speak an edit ("make this shorter", "turn into bullets") — the selection is replaced |
| Esc while recording | Cancel |
| Menu bar → Paste Last Transcript | Same as Ctrl + hotkey tap |
| Tap **Right ⌥** (Ask key) | Ask window opens for typing (mic off) |
| Tap **Right ⌥** again | Voice on: your words appear as you talk, after anything typed. Tap again to stop and keep editing |
| Hold **Right ⌥** | Talk while held (start after the chime); the words land in the Ask window |
| Return or the send button | Send (nothing is sent before this). Shift+Return = new line, Esc or ✕ = cancel |
| Tap **⌘** in the Ask window | Agent mode on or off: the outline turns green and Return hands it to the agent, which does it on your Mac (see Agent below) |
| **⌘I** in agent mode | Instant Edits on or off: a ⚡ Instant badge shows while it's on (see Instant Edits below) |
| Esc, or click **–** on the answer | Tuck it into a chip in the bottom-right corner (the answer keeps coming). Esc again or a click on the chip brings it back |
| **Shift+Esc**, Fn, or click ✕ | Close the answer (also cancels one still coming), from the bubble or the chip. Fn leaves a tucked answer alone. Right ⌥ closes it and starts a new question |

Command mode needs Apple Intelligence enabled (it's the edit engine) and isn't available when the main hotkey is ⌃⌥.

Hotkey options: Right ⌥ (default), Fn/🌐, Right ⌘, ⌃⌥. If you pick Fn, set System Settings → Keyboard → "Press 🌐 key to" = **Do Nothing** so macOS's own dictation stays out of the way.

Notes:
- Esc cancels the dictation but the keystroke also reaches the frontmost app (the hotkey listener is observe-only by design — it needs no Input Monitoring permission). Avoid Esc if the target app treats it destructively; a quick tap of the hotkey also cancels.
- Spoken "new line" / "new paragraph" commands are off by default (Settings → General) because they can misfire on dictation that legitimately contains those phrases. When on, they only trigger as standalone clauses.
- Hands-free recordings pause at 5 minutes (tap the key to keep talking). The window takes the keyboard while open, without switching apps, so typing and Return land in it; Fn + Delete and Fn + arrows edit in the box rather than starting the mic.

## Ask (screen questions)

Tap the Ask key (Right ⌥ by default, Settings → General) to type, and tap it again to talk. The question builds up in the Ask window, editable, and is sent only when you press Return or the send button. Then LocalFlow screenshots the display under your pointer (leaving its own windows and outline out) and sends both to a local vision model in [Ollama](https://ollama.com) at 127.0.0.1. Blue dots and "Thinking" show until the first word arrives, with a seconds count once it's been a few seconds. The answer streams into a bubble with copy, – and ✕ buttons. A new answer floats over everything, so the app you were in can't cover it before you've seen it. Once you click somewhere else it sits with your ordinary windows: click any app and it comes in front, click the bubble and it comes back. If another window covers it completely, it tucks itself into the corner chip. The blue screen outline shows only while Ask is looking: while you write the question, and from Send until the first word (not over an answer, not while tucked away).

- **ChatGPT instead (optional):** Settings → General → **Ask answers with: ChatGPT (your subscription)**. Ask then runs the Codex tool that ships inside the ChatGPT app, signed in with your ChatGPT account, so answers come out of your ChatGPT plan with no API key. It runs isolated from your own Codex setup (no config, hooks, MCP servers or rules) with its tools switched off, so text on your screen can't get it to run commands, read files or browse. It saves nothing to your Codex history, uses a read-only sandbox in an empty folder that's deleted, screenshot included, after each answer, and links in answers show as plain text. Default model `gpt-6-sol`, low reasoning effort. **This sends the screenshot and your question to OpenAI**; dictation stays on your Mac either way. The answer arrives whole rather than word by word.
- **Claude instead (optional):** Settings → General → **Ask answers with: Claude (your Claude plan)**, then **Sign in to Claude…**, which opens Terminal and runs Claude Code's own sign-in. Pick whichever Claude account Ask should use: the sign-in is LocalFlow's own, kept apart from your everyday Claude Code, so it can be a different account, and none of your Claude Code settings, hooks, plugins or CLAUDE.md load. Ask then runs Claude Code headless with no tools, no MCP servers, no slash commands and nothing saved, so text on your screen can't get it to run commands or read files; the screenshot sits in a private folder that's deleted after each answer. Default model `claude-sonnet-5-5`, low effort, and answers stream in word by word. Needs Claude Code installed. **This sends the screenshot and your question to Anthropic** and counts against your Claude plan's usage limits; dictation stays on your Mac either way.
- **Model:** `qwen3.5:9b` (6.6 GB download, about 6.4 GB in memory). Picked after testing the vision models on this M4 Max against real screenshots: it was the only small one that read every number correctly. `ollama pull qwen3.5:9b` once; change the tag in Settings.
- **Memory:** the model starts loading when the Ask window opens (so it loads while you talk or type) and unloads 5 minutes after the last answer.
- **Speed (M4 Max, 36 GB):** about 5 s from release to a full answer with the model warm, 12-13 s from cold.
- **Permission:** Screen Recording, asked for on first use. Dictation never needs it.
- **Copying:** drag over any words in the answer and press Cmd+C (Cmd+A selects it all), or use the copy button for the whole answer. Pressing on the words gives the bubble the keyboard; the buttons leave it with your app.
- **Chats:** every question and answer is saved on this Mac in `~/Library/Application Support/LocalFlow/ask-chats.json` (readable only by your account, never in the event log). The clock button in the Ask window or the answer, or **Ask Chats…** in the menu, opens every chat, grouped by day and searchable by anything said in it. From there: **Continue in Ask** (your next question picks that chat back up), **Copy Chat**, or **Delete**.
- **Follow-ups:** questions asked within 30 minutes of each other are one chat. Each new question carries the chat's last 5 questions and answers as text (Settings, 0 to 20; about 3,000 tokens at most), so "what about the second one?" works, even after a restart. Only the newest question carries a screenshot. **Start New Ask Chat** in the menu makes the next question start fresh.
- Pressing another key while the Ask key is held (Option+arrow, Option+letter) is treated as a shortcut: the window never opens, and inside the window it types the character.
- The window takes the keyboard while it's open (⌘V, ⌘A, ⌘Z work), without switching apps; Esc or sending hands it back.
- Weak spot: it reads screens reliably but multi-step reasoning (e.g. writing the next lines of code) can be wrong. Check its work.

## Agent

Tap **⌘** in the Ask window (or its **Agent** switch) so the outline turns green, write or say a task, and press Return. An agent then does it on your Mac like Claude Code: it runs Terminal commands (in the background too), reads and edits your files anywhere in your home folder, and looks at the screen, clicks, types and presses keys in apps. A panel in the top-right corner shows the task, each step in plain words ("Run the tests", "Click “New Message”"), and its reply when it's done; a green outline around the screen means it's working. **Stop** ends what it's doing; ✕ ends the session and stops anything it left running in the background (quitting LocalFlow does too).

- **Risky steps wait for you.** Looking, reading, searching and ordinary commands just run. Anything that deletes, sends, posts, buys, pushes, publishes, installs, uses sudo, touches system, shell-startup or LocalFlow's own files, opens a Terminal, script or System Settings, presses Return in a mail or chat app, or clicks a button like Send, Delete or Place order shows a card: **Deny**, **Allow**, or **Allow for this task** (that kind of step stops asking until you close the panel; commands it can't read in full only ever get **Allow**). **Allow only takes a real click** from your mouse or trackpad, so the agent can't approve its own steps; a click it posts just beeps. It's a list of known risky things, so watch what it does with apps and commands it doesn't know.
- **One window.** While the agent's panel is up, Ask writes in it instead of opening a second window. Tap ⌘ while the panel sits in its corner and its box opens right there, green: Return gives the same session more to do, with everything it already knows. Press the Ask key and the box moves to the bottom center, blue, for a question about the screen; ⌘ turns it green again. While you type in the panel, the agent's clicks and keystrokes wait, and its terminal work carries on.
- **Always allow** (Settings → General) lets every step run without a card, deleting, sending and sudo included. Only clicks on LocalFlow's own windows are still refused.
- **Connectors** (the puzzle-piece button in the Ask window or the panel, or Settings → Connectors) give the agent MCP servers, like Claude's connectors: GitHub (a personal access token, or your `gh` sign-in), a server by URL, or a local command. Tokens stay in the keychain. A connector's look-up tools just run; anything that changes something asks first.
- **How it runs:** Claude Code, headless, on your Claude plan through LocalFlow's own Claude sign-in (Settings → General → **Sign in to Claude…**), with none of your own Claude Code settings, hooks or CLAUDE.md. Default model `claude-opus-5-5` (Settings → **Agent model**). The screen tools are LocalFlow itself, started by Claude Code (`LocalFlow --computer-mcp`); they only run when LocalFlow started them, so no other program can borrow LocalFlow's Accessibility and Screen Recording. LocalFlow's own windows are left out of the agent's screenshots, and the panel moves to the other corner before the agent clicks where it is.
- **This sends screenshots, the files and command output it reads, and your task to Anthropic**, and counts against your Claude plan's usage limits. The event log records only kinds of steps, never your task, commands, typed text, paths or replies.

## Instant Edits

For one small change to how your own app or site looks ("make the Save button round", "more space under the header"). Turn it on with **⌘I** in agent mode and press Return. The panel shows each stage as it goes:

1. **Viewing screen**: a screenshot of the display you're on.
2. **Locating project**: a quick Claude Sonnet check works out which project is on screen from LocalFlow's memory (domains, logos, app names), your recent Instant runs, and any folders under Settings → **Instant Edits projects**, then shows its name. If it can't tell, it asks; answer with the folder or name and it remembers.
3. **Reading design profile**: the project's DESIGN.md, PRODUCT.md or similar, so the change uses its own colors, spacing and components.
4. **Making the change**: the step says what, such as "Making the Save button round instead of square".

Then the reply says what it changed and where, with **Undo** to put the files back. It edits the files on disk directly: no tests, builds, commits or deploys. The same check turns away anything bigger (redoing a whole screen) or anything that changes what the app does rather than how it looks, with "turn off Instant to run it". Guards limit a run to presentation code in that one project, at most 8 files and 200 lines, never settings, secrets or generated files, and a file the edit leaves broken is put back on its own.

## Memory

Ask and the agent share two files in `~/Library/Application Support/LocalFlow/Memory/` (Settings → General → **Memory** opens them):

- **localflow.md**: your standing instructions, like a CLAUDE.md of LocalFlow's own. Added to when you tell it how you like things ("always…", "from now on…").
- **flow-memory.md**: what they learn, mainly your projects: folder, repo, domains, and how to recognize them on screen. This is how Instant Edits and the agent know which project "this" is.

Both are read with every question and task, never hold secrets (anything that looks like a key or password is refused), and stay on this Mac apart from going with each question to the model you picked.

## Diagnostics

- `flow` in any terminal starts LocalFlow if it isn't running (`flow stop`, `flow restart`, `flow log`).
- `~/Library/Logs/LocalFlow.log` records each dictation's timing, mic device, peak level and paste result (never the words).
- The recorder rebuilds its audio engine on wake and input-device changes, and restarts capture once if audio stops arriving mid-recording.

## Build & install

```bash
cd ~/localflow
swift test          # unit tests (clipboard, live loop, audio stats, log, render, Ask flow)
LOCALFLOW_E2E=1 swift test   # + real Ollama answer and on-screen bubble/outline checks (flashes ~3 s)
./build.sh          # builds release, assembles ~/Applications/LocalFlow.app, signs
ln -sf ~/localflow/bin/flow ~/.local/bin/flow
open ~/Applications/LocalFlow.app
```

First run:
1. Grant **Microphone** when prompted.
2. Grant **Accessibility** (System Settings → Privacy & Security → Accessibility → enable LocalFlow). Needed to see the hotkey and to paste.
3. Wait for the one-time Parakeet model download (~500 MB, progress in the menu bar status).
4. For AI polish, Apple Intelligence must be enabled in System Settings.
5. For Ask: `ollama pull qwen3.5:9b`, then allow **Screen Recording** the first time you open the Ask window.

**Ad-hoc signing caveat:** permissions are tied to the app's signature. After every rebuild you must re-toggle LocalFlow in Accessibility settings. If that gets old, create a free Apple Development certificate in Xcode and put its name in `build.sh`.

## Privacy posture

- No network calls except the one-time model downloads (FluidAudio's models from Hugging Face; Apple's models from Apple).
- Audio is held in memory only, never written to disk.
- Dictation history is in-memory by default (Settings → "Save history to disk" to opt in).
- Ask chats are saved to disk (see Ask → Chats) so they can be searched; delete any from Ask Chats.
- The agent and Instant Edits send what they work with to Anthropic; see Agent above.
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
