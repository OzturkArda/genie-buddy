"""Talk to Genie Buddy from a shell, a script or a hook. Standard library only.

  genie.py poke "Nightly build finished" --kind done
  genie.py poke "Integration tests failed. Retry?" --kind question --options "Retry,Leave it" --wait 1800
  genie.py heartbeat "nightly build" --detail "41/60 jobs" --every 300
  genie.py heartbeat "nightly build" --state finished
  genie.py answer 3
  genie.py status

--wait blocks until you click a button and prints the answer (exit 2 on timeout).
"""
import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

BASE_URL = os.environ.get("GENIE_URL", "http://127.0.0.1:8777").rstrip("/")


def call(method, path, payload=None):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(BASE_URL + path, data=data, method=method,
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=10) as res:
            return json.loads(res.read())
    except urllib.error.HTTPError as e:
        return json.loads(e.read() or b"{}") | {"http_status": e.code}
    except OSError as e:
        return {"error": f"Genie not reachable at {BASE_URL}: {e}"}


def default_agent():
    return os.environ.get("GENIE_AGENT") or Path.cwd().name


def wait_for_answer(poke_id, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        res = call("GET", f"/answer/{poke_id}")
        if res.get("status") in ("answered", "seen") or "error" in res:
            return res
        time.sleep(2)
    return {"id": poke_id, "status": "pending", "timed_out": True}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("poke")
    p.add_argument("title")
    p.add_argument("--body", default="")
    p.add_argument("--kind", default="info", choices=["info", "progress", "done", "question", "blocker"])
    p.add_argument("--agent", default=None)
    p.add_argument("--options", default="", help="comma-separated button labels")
    p.add_argument("--wait", type=float, default=0, help="seconds to wait for your answer")
    h = sub.add_parser("heartbeat")
    h.add_argument("job")
    h.add_argument("--detail", default="")
    h.add_argument("--every", type=float, default=300, help="seconds until the next heartbeat")
    h.add_argument("--state", default="running", choices=["running", "finished", "failed"])
    h.add_argument("--agent", default=None)
    a = sub.add_parser("answer")
    a.add_argument("id", type=int)
    sub.add_parser("status")
    args = ap.parse_args()

    if args.cmd == "poke":
        options = [o.strip() for o in args.options.split(",") if o.strip()]
        res = call("POST", "/poke", {"title": args.title, "body": args.body, "kind": args.kind,
                                     "agent": args.agent or default_agent(), "options": options})
        if "id" in res and args.wait:
            res = wait_for_answer(res["id"], args.wait)
    elif args.cmd == "heartbeat":
        res = call("POST", "/heartbeat", {"job": args.job, "detail": args.detail, "every_s": args.every,
                                          "state": args.state, "agent": args.agent or default_agent()})
    elif args.cmd == "answer":
        res = call("GET", f"/answer/{args.id}")
    else:
        res = call("GET", "/status")
    print(json.dumps(res, indent=2))
    if "error" in res:
        sys.exit(1)
    if res.get("timed_out"):
        sys.exit(2)


if __name__ == "__main__":
    main()
