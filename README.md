# Genie Buddy

A pixel-art genie lives in a lamp on your taskbar. When your AI agent finishes a long job,
gets stuck or has a question, the genie comes out of the lamp and tells you. If you don't
notice, it flies over to your mouse. You can answer its questions with a click, and the
answer goes back to the agent.

It works with Claude Code and Codex out of the box, and with any other tool that can send an
HTTP request or use MCP.

> **Windows only for now.** Genie Buddy is built and tested on Windows 10 and 11. The code is
> cross-platform in principle (see [Mac and Linux](#mac-and-linux)), but no Mac or Linux build
> is published yet.

## Quick start

1. Download `GenieBuddy-windows-x64.zip` from the
   [latest release](https://github.com/OzturkArda/genie-buddy/releases/latest).
2. Unzip it anywhere, for example into `Documents\GenieBuddy`.
3. Double-click `GenieBuddy.exe`. A golden lamp appears above the bottom-right of your taskbar,
   and the genie says hello.

   Windows may show **"Windows protected your PC"**, because the app is not code-signed. Click
   **More info**, then **Run anyway**. You only need to do this once.
4. Right-click the lamp and choose **Test poke** to see the genie at work.

To start the genie with Windows, press `Win + R`, type `shell:startup`, and put a shortcut to
`GenieBuddy.exe` in the folder that opens.

## Connect your AI tools

The genie listens on `http://127.0.0.1:8777`, on your own computer only. Nothing is sent
anywhere else.

### Claude Code

Run these two commands inside Claude Code:

```
/plugin marketplace add OzturkArda/genie-buddy
/plugin install genie-buddy@genie-buddy
```

Then restart Claude Code. From then on:

- When a turn that took longer than a minute finishes, the genie tells you, with Claude's last message.
- When Claude needs your permission, the genie tells you to go back to the terminal.
- Claude gets `poke` and `heartbeat` tools, so it can ask you a question with buttons or keep
  the genie updated while it watches a long job.

### Codex

Add these lines to `%USERPROFILE%\.codex\config.toml`:

```toml
notify = ["curl", "-s", "-m", "3", "-X", "POST", "http://127.0.0.1:8777/hook/codex", "-H", "Content-Type: application/json", "--data-raw"]

[mcp_servers.genie]
url = "http://127.0.0.1:8777/mcp"
```

`notify` makes the genie tell you when Codex finishes a turn. Codex allows only one `notify`
program, so if you already have one, keep yours and skip that line. The `mcp_servers` block
gives Codex the `poke` and `heartbeat` tools. It needs a Codex version that supports HTTP MCP
servers; for older versions, see [Other MCP tools](#other-mcp-tools).

### Other MCP tools

Cursor, Windsurf, VS Code and most other MCP clients accept a server URL. Add a server named
`genie` with the URL `http://127.0.0.1:8777/mcp`. In most tools the entry looks like this:

```json
{ "mcpServers": { "genie": { "url": "http://127.0.0.1:8777/mcp" } } }
```

If a tool only supports command-based MCP servers, use the bridge in `client/genie_mcp.py`. It
needs [uv](https://docs.astral.sh/uv/):

```
uv run --script C:\path\to\GenieBuddy\client\genie_mcp.py
```

### Scripts and anything else

Any program that can send an HTTP request can summon the genie:

```powershell
# PowerShell
Invoke-RestMethod -Method Post -Uri http://127.0.0.1:8777/poke -ContentType application/json `
  -Body '{"title": "Backup finished", "kind": "done"}'
```

```bash
# curl
curl -X POST http://127.0.0.1:8777/poke -H "Content-Type: application/json" \
  -d '{"title": "Deploy failed. Roll back?", "kind": "question", "options": ["Roll back", "Leave it"]}'
```

`client/genie.py` is a small command-line client with no dependencies, if you have Python.

## What the genie does

| Message kind | What happens |
|---|---|
| `done` | The genie celebrates and shows the news. If you don't click within 45 seconds, it flies to your mouse. |
| `question` | The genie points at its bubble, with one button per option. Your click goes back to the agent. |
| `blocker` | The genie looks worried and lightning flashes. It flies to your mouse after 45 seconds and starts shaking the screen after 3 minutes. |
| `info`, `progress` | Shown for 20 seconds, then the genie goes back into the lamp. |
| A watched job goes quiet | If an agent stops sending heartbeats, the genie warns you that the job has gone quiet. |
| You're away | When the mouse hasn't moved for 2 minutes, the genie holds its news and the lamp glows. When you come back, it greets you with a summary. |

- **Click the lamp** to call the genie. It shows the next message, or the jobs it is watching.
- **Drag the lamp** to move it.
- **Right-click the lamp, the genie or the tray icon** for test poke, mute, dismiss all and quit.
- **Later** snoozes a message for 10 minutes.

## API

All routes are on `http://127.0.0.1:8777`, with JSON bodies.

| Route | Body | Returns |
|---|---|---|
| `POST /poke` | `title`, and optionally `body`, `kind` (`info` `progress` `done` `question` `blocker`), `agent`, `options` | `id` |
| `GET /answer/<id>` | | `status` (`pending` `answered` `seen`) and `answer` |
| `POST /heartbeat` | `job`, and optionally `detail`, `every_s`, `state` (`running` `finished` `failed`) | `watching` |
| `GET /status` | | version, pending count, away flag, watched jobs |
| `POST /mcp` | MCP over Streamable HTTP | tools `poke`, `get_answer`, `heartbeat` |
| `POST /hook/claude` | a Claude Code hook event (`UserPromptSubmit`, `Stop`, `Notification`) | |
| `POST /hook/codex` | a Codex `notify` payload | |

Requests from web pages on other sites are refused, so a website cannot poke your genie.

## Build from source

You only need this to change the genie itself.

1. Install [Godot 4.7.1](https://godotengine.org/download) and its export templates
   (Editor → Manage Export Templates → Download).
2. Open `godot/project.godot` in Godot and press F5 to run it, or export the exe:

```
godot --headless --path godot --export-release "Windows" ../build/GenieBuddy.exe
```

GitHub Actions builds the same exe on every push (`.github/workflows/build.yml`). A tag like
`v0.2.0` publishes it as a release.

## Project layout

| Path | Contents |
|---|---|
| `godot/main.gd` | The window, presence detection, message queue, escalation and speech bubble |
| `godot/inbox.gd` | The HTTP server: plain JSON, MCP and hook events |
| `godot/genie_art.gd`, `godot/lamp_art.gd` | The pixel art, drawn in code |
| `godot/chime.gd` | Sounds, synthesised in code |
| `claude-plugin/` | The Claude Code plugin (MCP server and hooks) |
| `client/` | Command-line client and command-based MCP bridge |

## Mac and Linux

The genie is a Godot project, and Godot exports to macOS and Linux, so a port is mostly
packaging and testing. Contributions are welcome. What to expect:

- **macOS:** transparent windows, click-through and the menu-bar icon are all supported by
  Godot. The work is code signing and notarisation, without which Gatekeeper blocks the app.
  Unsigned builds can be opened with right-click → Open. Check the lamp's position against the
  Dock and the menu bar.
- **Linux on X11:** transparency and click-through work. The tray icon depends on the desktop
  environment's tray support.
- **Linux on Wayland:** Wayland does not let apps make parts of a window click-through, so the
  transparent window would block clicks on everything under it. Run the genie under XWayland
  with `--display-driver x11`.
- **All platforms:** add an export preset per platform to `godot/export_presets.cfg` and a job
  per platform to the workflow. The hooks use `curl`, which macOS and most Linux distributions
  ship with.

## Known limitations

- The genie shows a taskbar button while it runs.
- The exe file uses Godot's icon; the window and tray use the genie's.
- "Away" is judged by mouse movement only, so typing alone does not count as being present.
- Messages are kept in memory, so quitting the genie forgets them.

## License

MIT
