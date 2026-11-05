"""Writes a fake ~/.claude folder for screenshotting the Agents style in CI.

    python3 tools/agents_demo.py <empty dir> <pid of a live process>

Then run Screenie with SCREENIE_CLAUDE_DIR=<dir>. Never point this at a real ~/.claude.
"""
import json
import os
import random
import sys
import time
from datetime import datetime, timezone

out, pid = sys.argv[1], int(sys.argv[2])
if os.path.exists(os.path.join(out, "projects")) and os.path.basename(out.rstrip("/")) == ".claude":
    sys.exit("refusing to write into a real .claude folder")
rnd = random.Random(4)
now = time.time()

AGENTS = [
    ("aaaa1111-0000-4000-8000-000000000001", "/Users/demo/code/screenie", "Port the Farm style to Swift", "busy"),
    ("aaaa1111-0000-4000-8000-000000000002", "/Users/demo/code/screenie", "Fix radar sweep performance", "idle"),
    ("aaaa1111-0000-4000-8000-000000000003", "/Users/demo/code/website", "Write the release notes", "busy"),
    ("aaaa1111-0000-4000-8000-000000000004", "/Users/demo/code/billing-api", "Add invoice export endpoint", "busy"),
]
TOOLS = [("Read", "file_path"), ("Edit", "file_path"), ("Bash", "description"), ("Grep", None), ("Write", "file_path"),
         ("Glob", None), ("WebSearch", None)]
FILES = ["Farm.swift", "Hud.swift", "index.html", "README.md", "invoices.py", "routes.py", "Scene.swift"]


def ts(t):
    return datetime.fromtimestamp(t, timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


os.makedirs(os.path.join(out, "sessions"), exist_ok=True)
for i, (sid, cwd, title, status) in enumerate(AGENTS):
    slug = cwd.replace("/", "-")
    pdir = os.path.join(out, "projects", slug)
    os.makedirs(pdir, exist_ok=True)
    start = now - rnd.uniform(1800, 20000)
    with open(os.path.join(out, "sessions", f"{pid + i}.json"), "w") as f:
        json.dump(dict(pid=pid, sessionId=sid, cwd=cwd, name=title, status=status,
                       statusUpdatedAt=int((now - rnd.uniform(20, 400)) * 1000), startedAt=int(start * 1000),
                       entrypoint="cli"), f)
    lines = []
    t = start
    ctx = 20000
    n = 0
    while t < now - 5:
        if n % 25 == 0:
            lines.append(dict(type="user", userType="external", timestamp=ts(t), cwd=cwd, sessionId=sid,
                              message=dict(role="user", content="(demo prompt)")))
        t += rnd.uniform(4, 40)
        n += 1
        name, key = rnd.choice(TOOLS)
        inp = {}
        if key == "file_path":
            inp["file_path"] = f"{cwd}/{rnd.choice(FILES)}"
        elif key == "description":
            inp["description"] = rnd.choice(["Build the app", "Run tests", "List files", "Check git status"])
        out_tok = rnd.randint(80, 1500)
        ctx += rnd.randint(500, 4000)
        lines.append(dict(type="assistant", timestamp=ts(t), cwd=cwd, sessionId=sid, message=dict(
            id=f"msg_{sid[-4:]}_{n}", model="claude-opus-5-5", role="assistant",
            content=[dict(type="tool_use", id=f"tu_{sid[-4:]}_{n}", name=name, input=inp)],
            usage=dict(input_tokens=rnd.randint(1, 50), cache_creation_input_tokens=rnd.randint(0, 3000),
                       cache_read_input_tokens=ctx, output_tokens=out_tok,
                       output_tokens_details=dict(thinking_tokens=rnd.randint(0, out_tok))))))
        lines.append(dict(type="user", timestamp=ts(t + 1), cwd=cwd, sessionId=sid, message=dict(
            role="user", content=[dict(type="tool_result", tool_use_id=f"tu_{sid[-4:]}_{n}",
                                       is_error=rnd.random() < 0.03, content="(demo)")])))
    with open(os.path.join(pdir, f"{sid}.jsonl"), "w") as f:
        f.write("\n".join(json.dumps(l) for l in lines) + "\n")
print(f"demo agents written to {out}")
