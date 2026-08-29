# Removing HBIA — a guide for an AI agent

This removes the agent, the router and the workspace from a machine, and leaves **the licence**
behind so the machine can be used again without a new one.

## THE TWO FILES YOU MUST NOT DELETE

Inside the agent's directory (`~/hbia-agent`, or whatever it is called on this machine) there are
two files:

```
env-file
hexaeight.mac
```

**These are the HexaEight licence, and they are bound to THIS machine.** They were produced by
`hexaeight-activate newtoken`, which needs a licence code and a QR approval from the owner's phone.
You cannot recreate them, copy them from anywhere, or restore them from a backup taken elsewhere.

**Delete them and the licence is gone.** Reinstalling then requires the human to run `newtoken`
again with their licence code and phone — and if the code is single-use or already consumed, the
machine cannot be re-licensed at all.

So: **empty the agent directory of everything else, but never those two.** If you are unsure whether
a step will touch them, stop and ask.

`agent.uuid` sits beside them on some installs. Leave it too — it is identity, not state.

---

## 0. Find what is actually here

Directory names are a convention, not a rule. An install may use `hbia-agent01`, `identityagent`, or
anything else. Find them before removing anything:

```bash
# running components, and where they run FROM
for p in 5100 8770 5620 8899 8902 8903 8904 8907 1880 5623 5624; do
  pid=$(lsof -nP -tiTCP:$p -sTCP:LISTEN 2>/dev/null | head -1)
  [ -n "$pid" ] && printf '  %-5s pid=%-7s %s\n' "$p" "$pid" "$(ps -p $pid -o comm= 2>/dev/null)"
done

# the licence, wherever it lives — this names the agent directory
find "$HOME" -maxdepth 3 -name 'hexaeight.mac' 2>/dev/null
```

**Say what you found, and which directory you believe holds the licence, before you remove
anything.** Everything below assumes those names.

---

## 1. Stop it starting again, then stop it

Order matters. Removing the units first means nothing restarts underneath you while you work.

```bash
hexaeight-activate autostart off     # launchd agents / systemd --user units removed
hexaeight-activate stop all          # workspace, agent, router
```

**Check nothing survived.** A stale process holding a port is the classic way a "removed" install
appears to still be running:

```bash
for p in 5100 8770 5620 8899 8902 8903 8904 8907 1880 5623 5624; do
  (echo > /dev/tcp/127.0.0.1/$p) 2>/dev/null && echo "  $p STILL UP" || echo "  $p free"
done
```

Anything still up, stop by **port**, never by name — the agent runs as `./hexaeight-agent-<rid>`, a
relative path that most `pkill` patterns miss:

```bash
for p in 5100 8770 5620 8899 8902 8903 8904 8907 1880 5623 5624; do
  for pid in $(lsof -nP -tiTCP:$p -sTCP:LISTEN 2>/dev/null); do kill "$pid"; done
done
sleep 5
# still there? then, and only then:
for p in 5100 8770 5620 8899 8902 8903 8904 8907 1880 5623 5624; do
  for pid in $(lsof -nP -tiTCP:$p -sTCP:LISTEN 2>/dev/null); do kill -9 "$pid"; done
done
```

Node-RED and cloudflared are started by the agent and die with it. A `cloudflared` a human started by
hand does not — check for it separately:

```bash
pgrep -fl cloudflared || echo "  none"
```

---

## 2. Remove the state

Nothing here is recoverable, and none of it is the licence.

| path | what it holds |
|---|---|
| `~/.heia` | the runtime (Node, the pinned Claude CLI, the engines), the workspace bundle, `skills.db`, Node-RED's user dir, leaf runtime, logs |
| `~/agentwork` | everything turns and ingests have written — code, packages, leaves |
| `~/hbia-router` | the router binary and `upstreams.yaml` (**which holds provider API keys**) |
| `~/hbia-workspace` | the workspace install directory |

**`upstreams.yaml` holds live API keys.** Deleting the directory is enough on a machine being wiped;
if the disk is being kept or passed on, overwrite it first:

```bash
[ -f ~/hbia-router/upstreams.yaml ] && : > ~/hbia-router/upstreams.yaml
```

Then remove. **Rename first rather than deleting outright** — if something turns out to matter, a
rename is reversible for as long as the disk is:

```bash
TS=$(date +%Y%m%d_%H%M%S)
for d in ~/.heia ~/agentwork ~/hbia-router ~/hbia-workspace; do
  [ -e "$d" ] && mv "$d" "$d.removed_$TS" && echo "  $d -> $d.removed_$TS"
done
```

Delete them for good once the human confirms:

```bash
rm -rf ~/.heia.removed_* ~/agentwork.removed_* ~/hbia-router.removed_* ~/hbia-workspace.removed_*
```

---

## 3. Empty the agent directory — but keep the licence

**This is the step that can destroy something irreplaceable.** It removes everything in the agent
directory *except* the licence.

```bash
cd ~/hbia-agent || exit 1

# PROVE you are in the right place before removing anything.
ls -la env-file hexaeight.mac || { echo "NO LICENCE HERE - wrong directory, stop"; exit 1; }

TS=$(date +%Y%m%d_%H%M%S)
mkdir -p ../hbia-agent-removed_$TS
for f in * .[!.]*; do
  case "$f" in
    env-file|hexaeight.mac|agent.uuid) continue ;;    # THE LICENCE. Never moved, never deleted.
    ''|'.'|'..'|'*'|'.[!.]*') continue ;;
  esac
  mv -- "$f" ../hbia-agent-removed_$TS/ 2>/dev/null
done

echo "--- what remains (must be ONLY the licence) ---"
ls -la
```

**The final `ls` must show only `env-file`, `hexaeight.mac` and possibly `agent.uuid`.** Anything
else means the loop missed something; remove it by hand rather than re-running with `rm`.

What that took away: the agent binary, `hexaeight-agent.json`, the sealed engine store (`engines.he`),
all session stores (`sessions.he`, `proxysessions.he`, `worksessions.he`, `sessiontitles.he`), logs,
`external-sessions/`, `wakes/`, `localcache/`.

Delete the set-aside copy once confirmed:

```bash
rm -rf ~/hbia-agent-removed_*
```

---

## 4. The tool itself — only if asked

`hexaeight-activate` is a global .NET tool and is not part of the install. It is what you would use
to install again, so leave it unless the human asks:

```bash
dotnet tool uninstall -g HexaEight.Activate
```

---

## 5. Confirm, and say what was kept

```bash
echo "--- ports (all must be free) ---"
for p in 5100 8770 5620 1880; do
  (echo > /dev/tcp/127.0.0.1/$p) 2>/dev/null && echo "  $p STILL UP" || echo "  $p free"
done
echo "--- autostart (must list nothing) ---"
hexaeight-activate autostart status 2>/dev/null
echo "--- licence (must still be here) ---"
ls -la ~/hbia-agent/env-file ~/hbia-agent/hexaeight.mac 2>/dev/null
```

Report exactly this, filled in:

```
  Removed:  agent, router, workspace, ~/.heia, ~/agentwork
  Kept:     ~/hbia-agent/env-file and hexaeight.mac  (the machine licence)
  Autostart: removed
  Ports:    5100, 8770, 5620, 1880 all free
```

**Say the licence was kept, in those words.** The human needs to know they can reinstall without
their phone and their licence code — and if they wanted a full wipe, this is their chance to say so.

---

## Reinstalling afterwards

Follow INSTALL.md. It detects an existing licence and skips `newtoken`, so the install picks up from
the agent directory it finds. Nothing removed above needs to be restored — `install-agent`,
`install-runtime` and `install-workspace` fetch it all again.

---

## If the human really does want the licence gone

Only when they say so explicitly, and only after you have told them it cannot be undone:

```bash
rm -f ~/hbia-agent/env-file ~/hbia-agent/hexaeight.mac ~/hbia-agent/agent.uuid
rmdir ~/hbia-agent 2>/dev/null
```

After this the machine has no HexaEight identity. Using it again needs `hexaeight-activate newtoken`,
a licence code, and the owner's phone — and a code that has already been consumed may not permit a
second activation. Do not run this to "clean up"; run it only when asked for it directly.
