# Quickstart: Claude Micro

## 1. Server (on the Mac, ~5 min)

```bash
cd server
npm install
cp claude-micro.config.example.json claude-micro.config.json
# edit: give each device a named token (32+ random chars), list your project dirs
# (legacy single "token" is still accepted; named tokens let you revoke one device)
npm run dev          # or: npm run build && npm start
```

Requires Node 18+ and Claude Code already authenticated on this Mac (`claude` works in a
terminal). The server reuses those credentials via the Agent SDK — no extra API key needed
(set `ANTHROPIC_API_KEY` only if you want to force API billing).

Smoke test without any Apple device:

```bash
npx wscat -c ws://127.0.0.1:8787/ws
> {"v":1,"type":"hello","token":"<your token>","device":"other","name":"wscat"}
> {"v":1,"type":"create_session","projectId":"<id from config>"}
> {"v":1,"type":"prompt","sessionId":"<from snapshot/session_state>","text":"list the files here","source":"typed"}
```

## 2. Apple apps (Xcode 16+, ~15 min)

```bash
brew install xcodegen
cd apple && xcodegen
open ClaudeMicro.xcodeproj
```

Set your signing team on all three targets, plug in the iPhone, Run `ClaudeMicro`.
In the app (single bridge screen), tap **Scan pairing QR** (`npm run pair` on the Mac)
or enter `ws://<mac-lan-ip>:8787/ws` + token manually (also set
`bind` in the server config to your **specific LAN or Tailscale IP** — never `0.0.0.0`;
Constitution V requires loopback/Tailscale-scoped binding. On a plain LAN the token
travels in cleartext, so prefer Tailscale, which encrypts the link, when in doubt).
Then Run the `ClaudeMicroWatch` scheme on the paired Ultra 2.

## 3. Action button (watchOS 11+)

Watch Settings → **Action Button** → Shortcut → **Claude Primary Action**.
Press = approve pending permission; otherwise opens dictation for a voice prompt.

## 4. Remote (away from home)

Install Tailscale on Mac + iPhone, set server `bind` to the Tailscale IP, point the phone
at `ws://<tailscale-ip>:8787/ws`. The watch always rides through the phone.

## 5. Spec Kit loop (Claude Code CLI on the Mac)

```bash
uvx --from git+https://github.com/github/spec-kit.git specify init --here --ai claude
claude   # then: /speckit.analyze → fix drift → /speckit.implement (tasks.md tracks what's left)
```
