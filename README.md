# toi_companion v2

macOS menu bar app: push-to-talk to AI. A floating sticky note appears near your cursor, shows the live transcript, then streams the LLM response in real time, then fades away.

**Status:** Phase 1 complete. App runs, sticky note + PTT + STT + LLM streaming + settings window all working.

> **v2 starts from a clean slate.** The code is a copy of v1 (which broke — see [POSTMORTEM.md](POSTMORTEM.md)). The workflow rules are different this time: the user compiles, the user commits, the user pushes. This repo contains code only.

## What it does

- Lives in the macOS menu bar (no dock icon, no main window).
- Hold `Right Shift` → a floating sticky note appears near your cursor.
- The note fills in real-time: first with the live transcript of what you say, then with the streamed LLM response.
- Release the key → the note stays a couple of seconds, then fades away.
- Click the **↲** button (top-right) to edit the transcript by hand (for when the mic gets it wrong).
- Drag the **resize grip** (bottom-right) to resize the note.
- Click **×** (top-left) to dismiss.
- Settings window: model, font, theme, line spacing.

## Stack

| | |
|---|---|
| App | Swift 5.9+ / SwiftUI / AppKit (XcodeGen) |
| Deployment target | macOS 13.0+ |
| App Sandbox | ON (audio-input + network-client) |
| STT | Apple `SFSpeechRecognizer` |
| LLM | OpenAI `gpt-4o-mini` (streaming SSE) via Cloudflare Worker |
| Auth | Shared-secret in `X-Toi-Companion-Secret` header |

## Layout

```
toi_companion_v2/
├── app/             macOS app — XcodeGen generates ToiCompanion.xcodeproj
├── worker/          Cloudflare Worker proxy to OpenAI
├── scripts/         dev helpers
├── README.md        this file
└── POSTMORTEM.md    what happened to v1 and why this is v2
```

## One-time setup

### 1. Generate the Xcode project

```bash
cd app
xcodegen generate
```

### 2. Build the app

```bash
xcodebuild -scheme ToiCompanion -configuration Debug build
```

The `.app` lands in `~/Library/Developer/Xcode/DerivedData/ToiCompanion-*/Build/Products/Debug/ToiCompanion.app`.

### 3. Open the app

Double-click the `.app` from Finder (not from `open` on the command line — that path has a known issue with Input Monitoring permission on macOS 15).

### 4. Grant permissions

macOS will prompt for **Microphone** and **Speech Recognition** the first time. Then go to:

**System Settings → Privacy & Security → Input Monitoring**

and add the `.app` manually. Right now the app is unsigned (ad-hoc), so every rebuild gets a new cdhash and macOS will ask for the permission again. There's no way around this without an Apple Developer ID ($99/yr). The dev workflow accepts this as the cost of running unsigned.

### 5. Set up the Worker

```bash
cd worker
npm install
npx wrangler login
npx wrangler secret put OPENAI_API_KEY     # paste your OpenAI key
npx wrangler secret put TOI_SHARED_SECRET  # paste the same value as in step 6
npx wrangler deploy
```

The deploy prints a URL like `https://toi-companion-proxy.<your-subdomain>.workers.dev`.

### 6. Point the app at the Worker

In `app/ToiCompanion/Resources/Info.plist` (or via the Settings window after first launch), set:

- `WORKER_BASE_URL` = the URL from step 5
- `WORKER_SHARED_SECRET` = the same `TOI_SHARED_SECRET` you set on the Worker

(If the keys don't exist yet as `Info.plist` entries, add them — the LLM client reads them at launch.)

### 7. Restart the app

Quit and reopen. Hold Right Shift, speak, release. The sticky note should show the transcript and the LLM streaming response.

## Development rules (the v2 contract)

These are non-negotiable. They exist because v1 broke and we don't want a repeat.

1. **Claude does not touch Git.** No `git add`, no `git commit`, no `git push`, no `gh api`. The user is the only one who commits and pushes.
2. **Claude does not compile.** No `xcodebuild`, no `xcodegen generate` without explicit OK from the user.
3. **If it compiles, don't recompile.** macOS 15 + ad-hoc + Input Monitoring = every rebuild silently revokes the PTT permission. The user has to re-grant manually each time.
4. **Commit early, commit often.** After the user confirms a change works, the user commits. Don't batch changes waiting for "the right moment".
5. **Restore ≠ invent.** If the user asks to restore something, verify it exists before promising. If it doesn't exist, say so before reconstructing.
6. **No "one more try".** That phrase is a code smell in this project. If something isn't working, stop and ask the user.

## Roadmap

- [x] **Phase 1** — App runs, sticky note + PTT + STT + LLM streaming + settings window.
- [ ] **Phase 2** — Polish: cursor positioning across multiple screens, error states, model picker.
- [ ] **Phase 3** — Hotkey customization (configurable key, not just Right Shift).
- [ ] **Phase 4** — Auto-update (Sparkle) — requires Developer ID.
- [ ] **Phase 5** — Multi-tenant auth (each user brings their own OpenAI key) — removes the Worker requirement.

## License

TBD.
