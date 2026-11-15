#!/usr/bin/env bash
# Snapshot every tmux pane and the agent session (Claude Code / Codex) running in it.
# Read-only towards tmux: only list-* is used. Output: <dir>/snapshot-<UTC>.json + latest.json.
#   --socket PATH   tmux socket (default: $PNEUMA_TMUX_SOCKET or /tmp/tmux-<uid>/default)
#   --dir DIR       output dir (default: $PNEUMA_SESSION_RESTORE_DIR or ~/.cache/pneuma-session-restore)
#   --stdout        print JSON, write nothing
set -euo pipefail
SOCKET="${PNEUMA_TMUX_SOCKET:-/tmp/tmux-$(id -u)/default}"
DIR="${PNEUMA_SESSION_RESTORE_DIR:-$HOME/.cache/pneuma-session-restore}"
STDOUT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --socket) SOCKET="$2"; shift 2 ;;
    --dir) DIR="$2"; shift 2 ;;
    --stdout) STDOUT=1; shift ;;
    -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -S "$SOCKET" ] || { echo "snapshot: no tmux server at $SOCKET; nothing to snapshot" >&2; exit 0; }
mkdir -p "$DIR"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
export SOCKET DIR TS
OUT="$(python3 -I - <<'PY'
import json, os, re, subprocess, glob, datetime
sock = os.environ["SOCKET"]; home = os.path.expanduser("~")
link_dir = os.environ.get("PAPERCLIP_LINK_DIR", home + "/.local/state/paperclip-link")
tools = os.environ.get("PNEUMA_RESTORE_TOOLS", "k9s").split()
def tmux(*a):
    return subprocess.run(["tmux", "-S", sock, *a], capture_output=True, text=True).stdout
fmt = "\t".join("#{%s}" % f for f in ["session_name","window_index","window_name","pane_index","pane_id","pane_pid","pane_current_path","pane_current_command","pane_title"])
panes = [l.split("\t") for l in tmux("list-panes","-a","-F",fmt).splitlines() if l]
ps = {}
for l in subprocess.run(["ps","-eo","pid=,ppid=,args="],capture_output=True,text=True).stdout.splitlines():
    p = l.split(None, 2)
    if len(p) >= 2: ps[int(p[0])] = (int(p[1]), p[2] if len(p) > 2 else "")
kids = {}
for pid,(pp,_) in ps.items(): kids.setdefault(pp, []).append(pid)
def descendants(root):
    out, st = [], [root]
    while st:
        for c in kids.get(st.pop(), []): out.append(c); st.append(c)
    return sorted(out)
def cmdline(pid):
    try: return open(f"/proc/{pid}/cmdline","rb").read().decode(errors="replace").rstrip("\0").split("\0")
    except OSError: return []
def environ(pid):
    try: return dict(kv.split("=",1) for kv in open(f"/proc/{pid}/environ","rb").read().decode(errors="replace").split("\0") if "=" in kv)
    except OSError: return {}
def cwd(pid):
    try: return os.readlink(f"/proc/{pid}/cwd")
    except OSError: return None
links = {}
for f in glob.glob(link_dir + "/*"):
    try:
        d = json.load(open(f))
        if isinstance(d, dict) and "session" in d: links[os.path.basename(f)] = d
    except Exception: pass
def codex_file(sid): return glob.glob(f"{home}/.codex/sessions/*/*/*/rollout-*{sid}*.jsonl")
entries = []
for sess, widx, wname, pidx, pane_id, ppid, pcwd, pcmd, ptitle in panes:
    e = dict(session=sess, window_index=int(widx), window_name=wname, pane_index=int(pidx), pane_id=pane_id,
             pane_title=ptitle, cwd=pcwd, client="shell", launch=None, agent_pid=None, agent_cmdline=None,
             session_id=None, confidence=None, id_source=None, paperclip_slug=None, note="")
    desc = descendants(int(ppid))
    agent = None
    for pid in [int(ppid)] + desc:
        a = cmdline(pid)
        if not a: continue
        base = os.path.basename(a[0])
        if base == "claude": agent = ("claude", pid, a); break
        if base == "node" and len(a) > 1 and a[1].endswith("/codex"): agent = ("codex", pid, ["codex"] + a[2:]); break
    if agent is None:
        for pid in desc:
            a = cmdline(pid)
            if a and os.path.basename(a[0]) == "codex": agent = ("codex", pid, a); break
    if agent:
        client, apid, argv = agent
        e["client"] = client; e["agent_pid"] = apid; e["agent_cmdline"] = argv
        e["cwd"] = cwd(apid) or pcwd
        flags, skip = [], False
        for i, x in enumerate(argv[1:], 1):
            if skip: skip = False; continue
            if x in ("--resume","-r","--continue","-c") and client == "claude":
                if x in ("--resume","-r") and i+1 < len(argv) and not argv[i+1].startswith("-"): skip = True
                continue
            flags.append(x)
        e["flags"] = flags
        if client == "claude":
            for pid in desc:
                sid = environ(pid).get("CLAUDE_CODE_SESSION_ID")
                if sid: e.update(session_id=sid, confidence="confident", id_source="CLAUDE_CODE_SESSION_ID in child environ"); break
            if not e["session_id"]:
                pd = home + "/.claude/projects/" + re.sub(r"[/.]", "-", e["cwd"])
                fs = sorted(glob.glob(pd + "/*.jsonl"), key=os.path.getmtime)
                if fs: e.update(session_id=os.path.basename(fs[-1])[:-6], confidence="guess", id_source="newest jsonl for cwd")
        else:
            ar = [x for x in argv[1:] if x == "resume"]
            for slug, d in links.items():
                if d.get("client") == "codex" and d.get("pane") == pane_id and slug in ptitle and codex_file(d["session"]):
                    e.update(session_id=d["session"], confidence="confident", id_source=f"paperclip link {slug} (pane+title)")
        e["launch_base"] = " ".join([client] + [x for x in flags])
    elif pcmd in tools:
        e["launch"] = pcmd; e["note"] = "tool relaunched, no state"
    entries.append(e)
# Codex: resolve remaining panes by link pane id (unique) then by elimination.
claimed = {e["session_id"] for e in entries if e["session_id"]}
for e in entries:
    if e["client"] == "codex" and not e["session_id"]:
        c = [(s,d) for s,d in links.items() if d.get("client")=="codex" and d.get("pane")==e["pane_id"] and d["session"] not in claimed and codex_file(d["session"])]
        if len(c) == 1:
            e.update(session_id=c[0][1]["session"], confidence="confident", id_source=f"paperclip link {c[0][0]} (pane)"); claimed.add(c[0][1]["session"])
for e in entries:
    if e["client"] == "codex" and not e["session_id"]:
        c = [(s,d) for s,d in links.items() if d.get("client")=="codex" and d["session"] not in claimed and codex_file(d["session"])]
        left = [x for x in entries if x["client"]=="codex" and not x["session_id"]]
        if len(c) == len(left) == 1:
            e.update(session_id=c[0][1]["session"], confidence="inferred", id_source=f"paperclip link {c[0][0]} by elimination (other codex panes matched)")
            claimed.add(c[0][1]["session"])
for e in entries:
    if e["client"] == "codex" and not e["session_id"]:
        fs = sorted(glob.glob(f"{home}/.codex/sessions/*/*/*/rollout-*.jsonl"), key=os.path.getmtime)[::-1]
        for f in fs[:300]:
            try: m = json.loads(open(f).readline()).get("payload", {})
            except Exception: continue
            if m.get("cwd") == e["cwd"] and m.get("id") not in claimed:
                e.update(session_id=m["id"], confidence="guess", id_source="newest rollout for cwd"); break
    if e["session_id"]:
        for slug, d in links.items():
            if d["session"] == e["session_id"]: e["paperclip_slug"] = slug
        if e["client"] == "claude": e["launch"] = f"claude --resume {e['session_id']} " + " ".join(e["flags"])
        else:
            fl = " ".join(x for x in e["flags"] if x != "resume")
            e["launch"] = f"codex resume {e['session_id']} {fl}"
        e["launch"] = e["launch"].strip()
    elif e["client"] in ("claude","codex"):
        e["note"] = "session id not found; window restored as plain shell"
        e["launch"] = None
    e.pop("launch_base", None)
snap = dict(taken_at_utc=os.environ["TS"], socket=sock, host=os.uname().nodename, panes=entries)
print(json.dumps(snap, indent=2))
PY
)"
if [ "$STDOUT" = 1 ]; then printf '%s\n' "$OUT"; exit 0; fi
[ "$(printf '%s' "$OUT" | jq '.panes | length')" -gt 0 ] || { echo "snapshot: tmux server has no panes; keeping previous snapshot" >&2; exit 0; }
printf '%s\n' "$OUT" > "$DIR/snapshot-$TS.json.tmp"
mv "$DIR/snapshot-$TS.json.tmp" "$DIR/snapshot-$TS.json"
cp "$DIR/snapshot-$TS.json" "$DIR/latest.json.tmp"; mv "$DIR/latest.json.tmp" "$DIR/latest.json"
# keep the newest 288 (one day at 5 min)
ls -1t "$DIR"/snapshot-*.json 2>/dev/null | tail -n +289 | xargs -r rm -f
echo "$DIR/snapshot-$TS.json"
