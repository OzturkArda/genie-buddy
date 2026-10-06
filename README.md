# Genie Buddy

A desktop companion for long-running agent work. A pixel-art genie lives in a lamp on the
taskbar and comes out when an agent finishes something, hits a blocker, asks a question, or
goes silent.

## Run

```powershell
./run.ps1     # finds Godot via $env:GODOT or PATH
```

## What it does

| Situation | Genie |
|---|---|
| `done` | Celebrates, then points at the news. If nobody clicks within 45s, it flies to your cursor. |
| `question` | Points, with one button per option. Your click goes back to the agent. |
| `blocker` | Looks worried, with lightning. Flies to your cursor after 45s, then taps the glass every 20s from 3 min on. |
| `info` / `progress` | Shows for 20s, then goes back into the lamp. |
| Heartbeat goes quiet | Warns that the job has gone quiet when no heartbeat arrives within twice the promised interval. |
| You're away (mouse idle 2 min) | Stays in the lamp. The lamp glows and wobbles, with a badge count. When you come back it greets you with "While you were away: …". |

- **Lamp:** click to rub it (shows the next message, or the watch list), drag to move it.
- **Right-click the lamp, the genie or the tray icon:** test poke, mute, dismiss all, quit.
- **Later:** snoozes a message for 10 minutes.

## How agents talk to it

HTTP on `127.0.0.1:8777`:

| Route | Body / result |
|---|---|
| `POST /poke` | `{title, body?, kind?, agent?, options?}` → `{id}` |
| `GET /answer/<id>` | `{status: pending\|answered\|seen, answer}` |
| `POST /heartbeat` | `{job, detail?, every_s?, state?: running\|finished\|failed}` |
| `GET /status` | pending count, away flag, watch list |

- CLI (standard library only): `client/genie.py poke|heartbeat|answer|status` (see the docstring).
- MCP tools `poke`, `get_answer`, `heartbeat`:
  `claude mcp add -s user genie -- uv run --script /path/to/genie-buddy/client/genie_mcp.py`

## Layout

- `godot/`: Godot 4.7 project. `main.gd` holds the window, the inbox, presence detection, escalation and the bubble. `genie_art.gd` and `lamp_art.gd` are the procedural pixel art. `chime.gd` synthesises the sounds.
- `client/`: CLI and MCP server.

Messages are held in memory and are lost when the genie quits.
