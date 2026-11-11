# TermAI

An AI agent for iPhone with two chats. Point it at any OpenAI-compatible endpoint (base URL, API key, model IDs) and:

- **Terminal** — use it like a CLI. The agent runs commands on your servers over SSH, reads and writes files in an on-device workspace, and fetches URLs.
- **Cowork** — pick a folder in Files and describe a job. The agent reads, writes, moves and tidies the files in that folder, asking before each change.

The two chats are separate: each has its own history and sessions, and a run in one keeps going while you look at the other. The interface is Liquid Glass on iOS 26 and a translucent material on iOS 17 and 18.

## Install

Every push builds an unsigned IPA on GitHub Actions.

1. Open the latest **Build** run under the repository's *Actions* tab.
2. Download the `TermAI-unsigned-ipa` artifact and unzip it.
3. Sign and install `TermAI-unsigned.ipa` with your sideloading tool (AltStore, Sideloadly, TrollStore, or your own certificate).

The same run uploads a `screenshots` artifact with the app in each theme and both chats, plus `fallback-*` shots from iOS 18, where the glass is a blurred material.

## Use

First launch: type `/setup` and answer the prompts (profile name, base URL, API key, default model), or open `/config` for the settings screen. Add SSH hosts in `/config`.

The switch at the top moves between **Terminal** and **Cowork**. Beside it, the ring shows how full the open chat's context is; tap it for the breakdown.

| Input | What it does |
| --- | --- |
| plain text | send a prompt to the agent |
| `!uptime` | run a command on the selected SSH host yourself (terminal) |
| `/cowork`, `/terminal` | switch chat |
| `/folder [reset]` | open Files to pick the Cowork folder, or go back to the app's own |
| `/context [n\|auto\|off]` | show what fills the context; set the limit (`/context 32k`) or auto-compress |
| `/compact [focus]` | swap the history for a summary to save tokens |
| `/model [id]` | list or switch models |
| `/profile [name]` | list or switch API profiles |
| `/host [name\|off]` | list or switch SSH hosts |
| `/approve [ask\|auto]` | whether tool calls need your OK |
| `/theme [id]` | `dark`, `crt-green`, `crt-amber`, `light` |
| `/system [text\|reset]` | custom system prompt |
| `/new`, `/sessions [n]`, `/retry` | session control, per chat |
| `/copy`, `/export`, `/clear` | copy the last answer, share as Markdown, clear the screen |

The terminal's key row above the keyboard has `esc`, `/`, `!`, history `↑ ↓`, `tab` (complete a command), `^C` (stop the current run) and `paste`.

### Cowork

Tap the folder name (in the bar, on the start screen or under the message field) and the Files browser opens: choose any folder on the phone, in iCloud Drive or from another provider. There is no path to type. The choice is remembered across launches; until you make one, Cowork uses the app's own folder (Files › On My iPhone › TermAI).

Inside the folder the agent can list, search, read, write, edit, move and delete. Each step shows as a row you can expand to see its output. Overwriting and deleting are permanent (nothing goes to Recently Deleted), so keep approval on `ask` for folders you care about. The prompt says when a step would overwrite a file or delete a whole folder, and the folder cannot be changed while a task is running.

### Context and tokens

Every request resends the whole conversation, so a long chat costs more with each message. Three things keep that down:

- **`/context`** (or the ring) shows the estimated size of the next request, split into system prompt, tool definitions, your messages, the assistant's and tool results, next to the count the API reported for the last one.
- **`/compact`** has the model write a short summary and sends that in place of the history from then on. What is on screen stays.
- **Auto-compress**, on by default: at 80% of the context limit old tool output is trimmed during a run, and the chat is summarised before your next message. The limit is 64k tokens until you change it; lower it to spend less per request, raise it for models with room to spare.

Token counts are estimates (about four bytes a token), since every model counts differently.

## Safety model

- **Approval.** In the default `ask` mode every SSH command, file change and web request waits for your answer: `y` / `n` / `a` in the terminal, buttons in Cowork (`a` is always, for this session). Reading, listing and searching files does not ask.
- **Secrets.** API keys, passwords and private keys are stored in the iOS Keychain (this device only). They are never written to the JSON settings files.
- **Host keys.** The first connection to a host records its key (the fingerprint is printed); later connections are refused if the key changes.
- **Workspace.** File tools are confined to one folder: the app's Documents folder for the terminal, the folder you picked for Cowork. Paths that leave it, directly or through a symlink, are refused. Moving or deleting a symlink acts on the link, not on what it points to.
- **Network.** The app talks only to the endpoints and hosts you configure. Plain-`http` endpoints are allowed for LAN servers such as Ollama; the app warns when an API key would be sent over one.

SSH private keys must be Ed25519 or RSA in OpenSSH format.

## Development

```
TermKit/            Swift package
  Sources/TermCore  models, streaming client, agent loop, tools, context accounting (no UI, builds on Linux)
  Sources/TermSSH   SSH connection on top of Citadel
App/                SwiftUI app
  Glass.swift       the one place that touches the Liquid Glass API
project.yml         XcodeGen project definition
```

```sh
swift test --package-path TermKit      # unit tests (macOS or Linux)
xcodegen generate && open TermAI.xcodeproj
```

Liquid Glass needs Xcode 26 (the iOS 26 SDK). With an older Xcode the app still builds and uses the material fallback everywhere.

Two tests talk to real services and are skipped unless configured:

```sh
python3 TermKit/Tests/mock_server.py 8765 &
TERMAI_TEST_BASEURL=http://127.0.0.1:8765/v1 \
TERMAI_SSH_HOST=127.0.0.1 TERMAI_SSH_USER=me TERMAI_SSH_PASSWORD=… \
swift test --package-path TermKit
```
