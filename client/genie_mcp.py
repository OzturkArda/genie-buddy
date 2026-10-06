# /// script
# requires-python = ">=3.11"
# dependencies = ["mcp>=1.2,<2", "psutil"]
# ///
"""MCP server that lets Claude Code and Codex agents summon Genie Buddy.

Run with uv so the dependencies resolve on their own:
  claude mcp add -s user genie -- uv run --script /path/to/genie-buddy/client/genie_mcp.py
"""
import json
import os
import sys
import time
from pathlib import Path

import psutil
from mcp.server.fastmcp import FastMCP

sys.path.insert(0, str(Path(__file__).parent))
from genie import call, wait_for_answer  # noqa: E402

SESSIONS_DIR = Path.home() / ".claude" / "sessions"

mcp = FastMCP("genie", instructions=(
    "Genie Buddy is a character on the user's desktop. Use poke() to tell the user something "
    "they should not miss while away from the terminal (a long job finished, a blocker, a question), "
    "and heartbeat() while watching a long-running job so the genie notices if you go silent."))


def _agent_name():
    """The Claude session name of the calling agent, else its working directory."""
    try:
        proc = psutil.Process().parent()
        while proc is not None:
            rec = SESSIONS_DIR / f"{proc.pid}.json"
            if rec.exists():
                return json.loads(rec.read_text(encoding="utf-8")).get("name") or Path.cwd().name
            proc = proc.parent()
    except (psutil.Error, OSError, ValueError):
        pass
    return Path(os.getcwd()).name


@mcp.tool()
def poke(title: str, body: str = "", kind: str = "info", options: list[str] | None = None,
         wait_seconds: float = 0) -> dict:
    """Make the genie come out of its lamp and tell the user something.

    Args:
        title: One line the user reads first.
        body: Optional short detail.
        kind: info, progress, done, question or blocker. Blockers and questions chase the
              user's cursor and tap the glass until answered; info and progress show briefly.
        options: Button labels for a question, e.g. ["Retry", "Leave it"]. The clicked label
                 is returned as the answer.
        wait_seconds: Block up to this long for the user's click. With 0, return the poke id
                      at once and check later with get_answer.
    """
    res = call("POST", "/poke", {"title": title, "body": body, "kind": kind,
                                 "agent": _agent_name(), "options": options or []})
    if "id" in res and wait_seconds > 0:
        return wait_for_answer(res["id"], wait_seconds)
    return res


@mcp.tool()
def get_answer(poke_id: int) -> dict:
    """Status of a poke: pending, answered (with the clicked option) or seen."""
    return call("GET", f"/answer/{poke_id}")


@mcp.tool()
def heartbeat(job: str, detail: str = "", every_s: float = 300, state: str = "running") -> dict:
    """Tell the genie a watched job is alive. If no heartbeat arrives within about twice
    every_s, the genie warns the user that the job has gone quiet.

    Args:
        job: Stable name of the job, e.g. "nightly build #1234".
        detail: Short progress line, e.g. "41/60 jobs, integration tests running".
        every_s: Seconds until you will send the next heartbeat.
        state: running, or finished / failed to stop watching (poke separately for the news).
    """
    return call("POST", "/heartbeat", {"job": job, "detail": detail, "every_s": every_s,
                                       "state": state, "agent": _agent_name()})


if __name__ == "__main__":
    mcp.run()
