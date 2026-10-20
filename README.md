# ThatPet Ollama Extension

Makes the [ThatPet](https://thatpet.app) desktop pet react to **Ollama Desktop**: it thinks
while the model thinks, browses while it searches the web, celebrates when the reply is ready.
A small macOS menu bar app, next to ThatPet's own icon.

> Unofficial. Not affiliated with ThatLev/ThatPet or Ollama. It uses ThatPet's public hook
> helper and only reads Ollama's local files; it changes nothing inside either app.

## What it does

| Ollama | The pet |
|---|---|
| You send a message | Thinking |
| The model searches the web | Working, with the "Browsing the web…" bubble, until it starts writing |
| The reply is complete | Done (celebrating) |
| Ollama fails | Error |
| You stop the reply | Back to idle |

- **Menu bar icon** right next to ThatPet's (ThatPet's cat and Ollama's llama, read from the two
  apps at runtime). Green/red on-off switch, the current phase with a timer
  (`Browsing the web · 2:31 (6:02 total)`), ThatPet status and the last reaction.
- **Notification** when a reply that took 10 s or more is ready and Ollama is not on screen.
- **Checks itself after ThatPet or Ollama update** and tells you if something broke; if a ThatPet
  update drops the link, it restores it.
- **Updates itself** from this repository's releases, only with releases signed by the
  maintainer's key.
- Opens at login. No Python, no Terminal, no extra software.

## Install

Requirements: macOS 13 or later, [ThatPet](https://thatpet.app) 0.4 or later (tested with 0.4.0),
[Ollama Desktop](https://ollama.com/download) (tested with 0.40.6).

1. Download `ThatPet-Ollama-Extension-x.y.z.zip` from [Releases](../../releases/latest) and unzip it.
2. Drag **ThatPet Ollama Extension** to **Applications** and open it.
3. The app is not notarized by Apple (that needs a paid developer account), so the first time
   macOS blocks it: open **System Settings → Privacy & Security**, scroll down and click
   **Open Anyway** next to ThatPet Ollama Extension. Updates install without asking again.
4. Allow notifications if macOS asks.

The icon appears next to ThatPet's cat. From now on it opens at login by itself.

**ThatPet link.** Since ThatPet 0.4 the pet only reacts to agents connected in its menu. ThatPet
has no "Ollama" agent, so the extension reports to it as the *Hermes Agent* and links it with
ThatPet's own command (`ThatPet connect hermes`). That writes a small, inert plugin to
`~/.hermes/plugins/thatpet` (Hermes itself doesn't need to be installed). If the link ever goes
away, the menu shows **Reconnect to ThatPet**.

## Tips for Ollama

Web search results are long (20–115 KB of text). If they don't fit in the model's context,
Ollama cuts the start of the chat — including your question — and some models fail with
*"No user query found in messages"*. In Ollama's Settings raise **Context length** to 32k, start
a new chat for questions that need a search, and prefer models packaged by Ollama (e.g.
`qwen3.5:9b`) over community repackages.

## Privacy

The extension never reads, stores or sends your conversations. From Ollama's database it reads
only message ids, roles, dates and lengths; from Ollama's `app.log` only the line that marks the
end of a reply. Its only network access is the update check on `api.github.com`.

## How it works

- **Turn start:** a new message with a recent date in Ollama Desktop's database (opened
  read-only). Ollama rewrites whole chats with new ids but old dates; those rows are ignored.
- **Turn end:** the `POST /api/v1/chat/{id}` line Ollama writes to `~/.ollama/logs/app.log` when a
  reply stream ends (`chat stream error` right before it means stopped or failed).
- **Tools:** a `tool_calls` row, then a `tool` message with the result.
- **ThatPet:** events go through ThatPet's helper
  (`ThatPet hook --provider hermes`): `UserPromptSubmit` → thinking, `PreToolUse` → working,
  `Stop` → celebrating, `StopFailure` → error, `SessionStart` → idle. ThatPet drops a state after
  60 s without events, so the current one is repeated every 20 s. `SessionEnd` is never sent: it
  makes ThatPet quit.

Logs: `~/Library/Logs/ThatPet Ollama Extension.log` (menu → Show Log).

## Uninstall

Menu → **Quit Extension**, then drag the app from Applications to the Trash and remove
`~/Library/Application Support/ThatPet Ollama Extension`. To remove the ThatPet link:
`/Applications/ThatPet.app/Contents/MacOS/ThatPet disconnect hermes`.

## Development

```sh
scripts/build.sh                     # build/ThatPet Ollama Extension.app (Apple Silicon + Intel)
python3 tests/simulate.py "build/ThatPet Ollama Extension.app/Contents/MacOS/ThatPetOllamaExtension"
python3 tests/update_test.py         # self-update: signed, unsigned, same version, other app
scripts/release.sh 1.0.1 "What changed"
```

- `tests/simulate.py` plays real situations against a fake Ollama and a fake ThatPet and checks
  every event (expect `RESULT: ALL OK`). Run it after every change.
- `scripts/release.sh` sets the version, builds, runs the simulation (and stops if it fails),
  zips and signs the app, tags and creates the GitHub release. Installed apps update by
  themselves.
- Releases are signed with an Ed25519 key in `~/.config/thatpet-ollama-extension/` (create it once
  with `swift scripts/signing.swift keygen`). **Back it up**: installed apps only accept updates
  signed with it. The public key is in `Resources/Info.plist`.
- `swift scripts/make_icon.swift` redraws the app icon (an original design; the menu bar icon reads
  ThatPet's and Ollama's icons from the installed apps and never ships them).

## License

[MIT](LICENSE) © 2026 ImP4ncake
