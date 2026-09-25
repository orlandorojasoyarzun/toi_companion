# toi_companion

macOS menu bar app: push-to-talk to AI. A floating sticky note appears near your cursor and fills in real-time with the model's response, then fades away.

**Status:** v0.1.0 — bootstrap phase. Skeleton only.

## What it does

- Lives in the macOS menu bar (no dock icon, no main window).
- Hold `Right Option` → a floating sticky note appears near your cursor.
- The note fills in real-time: first with the live transcript of what you say, then with the streamed LLM response.
- Release the key → the note stays a couple of seconds, then fades away.
- No audio output. Just text on the screen.

## Stack

| | |
|---|---|
| App | Swift 5.9+ / SwiftUI / AppKit (XcodeGen) |
| Deployment target | macOS 13.0+ |
| App Sandbox | ON (audio-input + network-client) |
| STT | Apple `SpeechAnalyzer` (on-device) |
| LLM | OpenAI `gpt-4o-mini` (streaming SSE) |
| Proxy | Cloudflare Worker (TypeScript, Wrangler) |
| Auth | Shared-secret in `X-Toi-Companion-Secret` header |

## Layout

```
toi_companion/
├── app/           macOS app — XcodeGen generates ToiCompanion.xcodeproj
└── worker/        Cloudflare Worker proxy to OpenAI
```

## Setup

### Worker

```bash
cd worker
npm install
wrangler login
wrangler secret put OPENAI_API_KEY        # paste your OpenAI key
wrangler secret put TOI_SHARED_SECRET     # paste any 32-byte hex secret
wrangler deploy
```

Note the deployed Worker URL. You will plug it into the app in Phase 4.

### App

```bash
brew install xcodegen
cd app
xcodegen generate
xcodebuild -scheme ToiCompanion -configuration Debug build
open ./build/Debug/ToiCompanion.app
```

## Development

- `scripts/bootstrap.sh` — one-shot setup (installs deps, generates xcodeproj).
- Each `fase` of the implementation plan produces one PR.
- See `/Users/orlandorojas/.claude/plans/cuddly-sleeping-hearth.md` for the full plan.

## License

TBD.