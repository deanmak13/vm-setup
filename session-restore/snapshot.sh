#!/usr/bin/env bash
# Snapshot every tmux pane and the agent session (Claude Code / Codex) running in it.
# Read-only towards tmux: only list-* is used. Output: <dir>/snapshot-<UTC>.json + latest.json.
#   --socket PATH   tmux socket (default: $PNEUMA_TMUX_SOCKET or /tmp/tmux-<uid>/default)
#   --dir DIR       output dir (default: $PNEUMA_SESSION_RESTORE_DIR or ~/.cache/pneuma-session-restore)
#   --stdout        print JSON, write nothing
set -euo pipefail
umask 077
command -v jq >/dev/null || { echo "snapshot: jq is required" >&2; exit 1; }
SOCKET="${PNEUMA_TMUX_SOCKET:-}"   # empty = let tmux pick its own socket (tmux's ownership checks apply)
SOCKNAME=""
DIR="${PNEUMA_SESSION_RESTORE_DIR:-$HOME/.cache/pneuma-session-restore}"
STDOUT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --socket) SOCKET="$2"; shift 2 ;;
    --socket-name) SOCKNAME="$2"; shift 2 ;;
    --dir) DIR="$2"; shift 2 ;;
    --stdout) STDOUT=1; shift ;;
    -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
# An explicit socket path is only trusted if its directory and the socket belong to us and the dir is private.
check_socket() {
  local s="$1" d; d="$(dirname -- "$s")"
  [ ! -L "$d" ] && [ -d "$d" ] && [ "$(stat -c '%u %a' -- "$d")" = "$(id -u) 700" ] || { echo "refusing socket $s: parent dir must be a non-symlink owned by uid $(id -u), mode 0700" >&2; exit 1; }
  [ -S "$s" ] && [ ! -L "$s" ] && [ "$(stat -c %u -- "$s")" = "$(id -u)" ] || { echo "refusing socket $s: not a socket owned by uid $(id -u)" >&2; exit 1; }
}
TM=(tmux)
if [ -n "$SOCKET" ]; then check_socket "$SOCKET"; TM=(tmux -S "$SOCKET"); SOCK_MODE=-S; SOCK_VAL="$SOCKET"
elif [ -n "$SOCKNAME" ]; then TM=(tmux -L "$SOCKNAME"); SOCK_MODE=-L; SOCK_VAL="$SOCKNAME"
else SOCK_MODE=""; SOCK_VAL=""; fi
"${TM[@]}" list-sessions >/dev/null 2>&1 || { echo "snapshot: no tmux server reachable; nothing to snapshot" >&2; exit 0; }
if [ -L "$DIR" ]; then echo "refusing: $DIR is a symlink" >&2; exit 1; fi
[ -e "$DIR" ] || mkdir -m 700 -p -- "$DIR"
[ -d "$DIR" ] && [ "$(stat -c %u -- "$DIR")" = "$(id -u)" ] || { echo "refusing: $DIR is not a directory owned by uid $(id -u)" >&2; exit 1; }
chmod 700 -- "$DIR"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
export SOCK_MODE SOCK_VAL DIR TS
OUT="$(python3 -I - <<'PY'
import json, os, re, subprocess, glob, datetime
sock = os.environ["SOCK_VAL"] or "(tmux default)"; home = os.path.expanduser("~")
link_dir = os.environ.get("PAPERCLIP_LINK_DIR", home + "/.local/state/paperclip-link")
tools = os.environ.get("PNEUMA_RESTORE_TOOLS", "k9s").split()
def tmux(*a):
    return subprocess.run(["tmux", *([os.environ["SOCK_MODE"], os.environ["SOCK_VAL"]] if os.environ["SOCK_MODE"] else []), *a], capture_output=True, text=True).stdout
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
import sys
ID_RE = re.compile(r"^[0-9a-fA-F-]{8,64}$"); VAL_RE = re.compile(r"^[A-Za-z0-9._/@-]+$"); NAME_RE = re.compile(r"^[A-Za-z0-9._-]+$")
NOVAL = {"--dangerously-skip-permissions", "--dangerously-bypass-approvals-and-sandbox"}
WITHVAL = {"--settings", "--name"}
def flags_ok(fl):
    i = 0
    while i < len(fl):
        if fl[i] in NOVAL: i += 1
        elif fl[i] in WITHVAL and i + 1 < len(fl) and VAL_RE.match(fl[i+1]): i += 2
        else: return False
    return True
def report(msg): print("snapshot: DROPPED " + msg, file=sys.stderr)
entries = []
for sess, widx, wname, pidx, pane_id, ppid, pcwd, pcmd, ptitle in panes:
    e = dict(session=sess, window_index=int(widx), window_name=wname, pane_index=int(pidx), pane_id=pane_id,
             pane_title=ptitle, cwd=pcwd, client="shell", launch=None, agent_pid=None, agent_cmdline=None, candidates=None,
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
        e["client"] = client; e["agent_pid"] = apid
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
        else:
            ar = [x for x in argv[1:] if x == "resume"]
            for slug, d in links.items():
                if d.get("client") == "codex" and d.get("pane") == pane_id and slug in ptitle and codex_file(d["session"]):
                    e.update(session_id=d["session"], confidence="confident", id_source=f"paperclip link {slug} (pane+title)")
        e["launch_base"] = " ".join([client] + [x for x in flags])
    elif pcmd in tools:
        e["launch"] = [pcmd]; e["note"] = "tool relaunched, no state"
    entries.append(e)
# Claude fallback: newest jsonl per cwd, skipping ids used by another pane; panes sharing a cwd are ambiguous.
claimed = {e["session_id"] for e in entries if e["session_id"]}
need = [e for e in entries if e["client"] == "claude" and not e["session_id"]]
for cwd_ in {e["cwd"] for e in need}:
    grp = [e for e in need if e["cwd"] == cwd_]
    pd = home + "/.claude/projects/" + re.sub(r"[/.]", "-", cwd_)
    cand = [os.path.basename(f)[:-6] for f in sorted(glob.glob(pd + "/*.jsonl"), key=os.path.getmtime)[::-1]]
    cand = [c for c in cand if c not in claimed and ID_RE.match(c)][:len(grp) + 2]
    if len(grp) == 1 and cand:
        grp[0].update(session_id=cand[0], confidence="guess", id_source="newest unclaimed jsonl for cwd")
    elif len(grp) > 1:
        for e in grp:
            e.update(confidence="guess", candidates=cand, note=f"ambiguous: {len(grp)} panes share cwd; NOT auto-resumed; candidates (newest first): {', '.join(cand)}")
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
        if not ID_RE.match(e["session_id"]) or not flags_ok(e["flags"]):
            report(f"launch for {e['session']}:{e['window_index']} (bad session id or flag: {e['session_id']!r} {e['flags']!r}); window kept as plain shell")
            e["launch"] = None; e["note"] = "launch dropped: failed validation"
        elif e["client"] == "claude": e["launch"] = ["claude", "--resume", e["session_id"]] + e["flags"]
        else: e["launch"] = ["codex", "resume", e["session_id"]] + [x for x in e["flags"] if x != "resume"]
    elif e["client"] in ("claude","codex"):
        e["note"] = e["note"] or "session id not found; window restored as plain shell"
        e["launch"] = None
    e.pop("launch_base", None); e["agent_cmdline"] = e["launch"] if e["client"] in ("claude", "codex") else None
ok = []
for e in entries:
    if NAME_RE.match(e["session"]) and NAME_RE.match(e["window_name"]): ok.append(e)
    else: report(f"pane {e['session']!r}:{e['window_index']} {e['window_name']!r} (name fails ^[A-Za-z0-9._-]+$)")
entries = ok
snap = dict(taken_at_utc=os.environ["TS"], socket=sock, host=os.uname().nodename, panes=entries)
print(json.dumps(snap, indent=2))
PY
)"
if [ "$STDOUT" = 1 ]; then printf '%s\n' "$OUT"; exit 0; fi
[ "$(printf '%s' "$OUT" | jq '.panes | length')" -gt 0 ] || { echo "snapshot: tmux server has no panes; keeping previous snapshot" >&2; exit 0; }
TMPF="$(mktemp -p "$DIR" .snapshot.XXXXXX)"; TMPL="$(mktemp -p "$DIR" .latest.XXXXXX)"   # mktemp creates 0600, same dir
trap 'rm -f -- "$TMPF" "$TMPL"' EXIT
printf '%s\n' "$OUT" > "$TMPF"; printf '%s\n' "$OUT" > "$TMPL"
mv -- "$TMPF" "$DIR/snapshot-$TS.json"; mv -- "$TMPL" "$DIR/latest.json"
# keep the newest 288 (one day at 5 min)
ls -1t "$DIR"/snapshot-*.json 2>/dev/null | tail -n +289 | xargs -r rm -f
echo "$DIR/snapshot-$TS.json"
