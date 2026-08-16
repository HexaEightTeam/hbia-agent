# Installing HBIA — a guide for an AI agent

You are installing a **HexaEight Bridge Identity Agent** on this machine. Follow these steps in
order. **Verify each step before moving on** — every step below has a check, and skipping one
produces a failure that appears several steps later with a misleading message.

## HOW TO WORK — read this before the first command

- **When this guide is unclear, wrong, or does not match what you actually see: STOP and say so**,
  quoting the guide's text against the real output. Do not improvise a workaround and carry on. A
  gap you route around silently is a gap that stays broken for the next person.
- **Never invent** a path, a route name, a model id, a hash, or a version. If you do not know it,
  it is discoverable by a command in this guide, or it is a question for the human.
- **Report what you observed, not what you expected.** Do not call a step done unless its check
  passed. "It probably worked" is how a broken install reaches step 7 before anyone notices.
- **Adopt what is already here.** This machine may hold a licence, a running component, or a
  previous install. The next section finds them. Never recreate or overwrite something that exists
  because a path in this guide is named differently.

## TWO THINGS ONLY THE HUMAN CAN DO

Everything else in this guide is yours. These two are not — ask for them, wait, and do not attempt
to work around either.

1. **The HexaEight licence** — `hexaeight-activate newtoken`. It needs a licence code and a QR
   approval from the HexaEight Authenticator app on their phone. It produces `env-file` and
   `hexaeight.mac`, which are bound to this machine. You cannot create, copy or fake them.
2. **The provider API key** — the Bedrock / z.ai / OpenAI key that goes into the router. Ask for it
   when you reach step 3. Do not guess one, and do not continue without it.

Ask for both **at the start**, together, so the human is interrupted once rather than twice.

**And one question to ask, not decide: WHICH MODEL.** After the key works you will run
`hexaeight-activate models`, which lists exactly what that key can reach. **Show the human that list
and ask which model to use.** Do not pick for them — the list usually contains models from several
vendors at very different prices, and the choice is theirs. You need their answer in step 5.

---

## THE WHOLE INSTALL, IN ONE PLACE

This is the shape of it. **Do not run these blind** — each has a check below that catches a failure
which would otherwise surface three steps later wearing a different message. Read the section when a
step does not do what this table says.

| # | command | what it gives you |
|---|---|---|
| — | `hexaeight-activate newtoken` | the licence. **Human only** |
| 2 | `dotnet tool install/update --global HexaEight.Activate` | the tool, **1.0.32+** |
| 3 | `hexaeight-activate install-router` → `upstreams` → `models` | the router, a provider key, and the model list to show the human |
| 4 | `hexaeight-activate install-agent` | the agent, the pinned toolchain, and the `harness` + `mindmapchat` engines |
| 4 | `hexaeight-activate sandbox` | proof turns can be confined. **Do not start the agent if this says INSTALLED BUT CANNOT RUN** |
| 5 | `hexaeight-activate engine --auto` | all three engines sealed against the router, in one pass |
| 6 | `hexaeight-activate install-workspace` | the browser UI on 5620 |
| 7 | ask it a question in the browser | proof it works end to end |
| 7b | `hexaeight-activate autostart on` | it all comes back after a reboot. **Without this, nothing does** |
| 8 | hand over the workspace URL | the human knows where to click |

Three directories, one identity, and the order matters: the router must answer before the agent
starts, and the agent must be sealed before the workspace shows anything.

**THE TWO THAT SILENTLY PRODUCE A DEAD INSTALL.** Both leave every component running and every
check green, and both surface as a turn that will not answer:

1. **macOS: the jail mask must name the credential FILES, not the licence folder.** The engine is
   started inside the licence folder, so a folder-wide deny kills it instantly with `EPERM`. See
   the macOS section in step 4. **Linux is unaffected.**
2. **The engines must be sealed to an `anthropic`-shaped route.** All three speak anthropic; an
   `-oai-` route fails at the provider with `400 modelCode: does not exist`, which looks like a bad
   model id and is not. See step 5.
3. **A personal `~/.claude/settings.json` overrides HBIA and takes the `claude` engine off the
   router** — same misleading `400`. Check for it in step 5, tell the human, and **ask** before
   touching their file. `harness` and `mindmapchat` are immune.

---

## FIRST: fix one set of paths, and find what is already installed

Do this before anything else. Two things routinely make one machine look like two, and guessing
either way is how a working setup gets duplicated or destroyed.

### 1. Resolve HOME once, and use that string everywhere

macOS reports the same directory under more than one path — `/Users/you` and
`/Volumes/Macintosh_HD/Users/you` are usually **the same place**, reached through a firmlink. A
shell may report either as its working directory.

```bash
H="$(cd ~ && pwd -P)"; echo "$H"
```

Use `$H` for the rest of the install. Do not mix the two spellings in one session.

**If you meet two paths and cannot tell whether they are one directory, ask the filesystem** —
same device and inode means same directory, whatever the paths look like:

```bash
stat -f '%d:%i' /Users/you/hbia-agent /Volumes/Macintosh_HD/Users/you/hbia-agent   # macOS
stat -c '%d:%i' /path/a /path/b                                                    # Linux
```

Identical output = one directory seen twice. **Different output = genuinely two**, and then you
must ask the human which is real rather than choose.

### 2. Find what is already running, and adopt it

This guide writes `~/hbia-agent`, `~/hbia-router`, `~/hbia-workspace`. **Those names are a
convention, not a requirement** — an earlier install may have used `hbia-agent01` or anything else.
A running component is the authority on where it lives:

```bash
# macOS
for p in 8770 5100 5620; do
  pid=$(lsof -ti tcp:$p 2>/dev/null | head -1)
  [ -n "$pid" ] && printf "  %-5s pid %-7s %s\n" "$p" "$pid" "$(ps -o comm= -p $pid)"
done
# Linux: same, or  readlink -f /proc/<pid>/exe
```

**Whatever directory the running binary sits in IS that component's directory.** Use it. Do not
install a second copy next to it because the name does not match this guide — that is how a machine
ends up with two trees, one of them serving and one of them being configured.

If nothing is running, look for the binaries before assuming a fresh install:

```bash
ls -d "$H"/hbia-* 2>/dev/null
ls "$H"/hbia-*/hexaeight-agent-* "$H"/hbia-*/hexaeight-router-* 2>/dev/null
```

A directory holding only `env-file` and `hexaeight.mac` is licence-only: nothing is installed there
yet, and it is a fine place to install into. A directory that also holds a binary and a
`hexaeight-agent.json` is an existing install — **upgrade it in place**, do not start a new one
elsewhere.

### 3. Say what you found before you change anything

State plainly: which directory each component lives in, which are running, and which you are about
to write to. If two candidates disagree and the inode test says they are genuinely different, stop
and ask. One sentence of confirmation costs less than a duplicated install.

---

## Platform notes — read the one that applies

**macOS**

- Binaries are `hexaeight-agent-osx-arm64` / `hexaeight-router-osx-arm64`. Wherever this guide
  writes `hexaeight-agent-linux-x64`, use the `osx-arm64` name — or the glob `./hexaeight-agent-*`.
- **Clear the quarantine flag** after a download, or the binary will not run:
  ```bash
  xattr -d com.apple.quarantine ./hexaeight-agent-osx-arm64 2>/dev/null; chmod +x ./hexaeight-agent-*
  ```
- **The sandbox is `sandbox-exec`, built into the OS.** `hexaeight-activate sandbox` should say
  WORKING with nothing to install. There is no bubblewrap on macOS, and nothing to `sudo apt` —
  if you find yourself installing a sandbox on a Mac, you are following the Linux path by mistake.
- There is no `/proc`, so any recipe reading `/proc/<pid>/exe` is Linux-only. Use the port-based
  procedure in this guide, which works on both.
- `ss` does not exist; use `lsof -ti tcp:<port>` (present on every Mac).

**Linux**

- Binaries are `-linux-x64`. The sandbox is **bubblewrap**, a `sudo` install, and on Ubuntu 23.10+
  it may install successfully and still be unable to run — see step 4, and check *before* starting
  the agent.

---

## 0. What you are building

Three components, each in its own directory, all sharing one identity:

| component | port | what it does |
|---|---|---|
| **router** | 5100 | holds the provider API keys; agents reach models through it and never hold a key |
| **agent** | 8770 | the identity, its engines, skills and leaves |
| **workspace** | 5620 | the browser UI |

The agent talks to the router over loopback. A browser talks to the agent.

**Throughout this guide, `~/hbia-agent`, `~/hbia-router` and `~/hbia-workspace` mean "the directory
that component actually uses on this machine"** — as established in the section above. If the agent
here lives in `hbia-agent01`, then every `cd ~/hbia-agent` in this guide means `cd ~/hbia-agent01`.
Substitute silently and keep going; do not create the directory this guide happens to name.

---

## 1. Prerequisites — check, do not assume

```bash
dotnet --version          # 8.0 or newer
node --version            # 20 or newer
```

Install .NET from https://dotnet.microsoft.com/download if missing.

### If the directories and licence already exist — READ THIS FIRST

A machine that has been set up before, or partially, will already have `~/hbia-agent`,
`~/hbia-router`, `~/hbia-workspace` containing `env-file` and `hexaeight.mac`. **This is the normal
case for a reinstall, and those two files are the one thing you must not touch.**

**Never** modify, move, rename, delete, overwrite, copy, or "clean up" `env-file` or
`hexaeight.mac`. Not to reorganise directories, not to make a backup, not because a step seems to
want a fresh start. `hexaeight.mac` is bound to this machine and cannot be regenerated by copying
one back; a copied `env-file` goes stale the moment the licence is renewed. Losing or corrupting
them means the human has to obtain a new licence.

Everything else in those directories — binaries, `.json`, `.he`, logs — is reinstallable and may be
replaced freely.

**Verify the existing licence rather than assuming it is good, and rather than replacing it:**

```bash
for d in ~/hbia-agent ~/hbia-router ~/hbia-workspace; do
  [ -d "$d" ] || continue
  echo "== $d"
  (cd "$d" && hexaeight-activate verify-env 2>&1 | grep -aiE "identity|congratulations|fail" | head -3)
done
```

- **Reports the licence installed and working** → the licence is fine. Skip the rest of step 1 and
  go to step 2. Do **not** run `newtoken`.
- **Fails in one directory but works in another** → that directory's files are stale or were copied
  rather than hardlinked. Do not delete anything: hardlink the working ones over, which replaces
  only the broken copy:
  ```bash
  ln -f ~/hbia-agent/env-file      ~/hbia-router/env-file
  ln -f ~/hbia-agent/hexaeight.mac ~/hbia-router/hexaeight.mac
  ```
  Then re-verify.
- **Fails everywhere** → the licence may have expired. **Report it and ask the human**; do not run
  `newtoken` yourself and do not delete the files.

**The identity.** Each component directory needs `env-file` and `hexaeight.mac`:

```bash
ls ~/hbia-agent/env-file ~/hbia-agent/hexaeight.mac
```

If those do not exist, **stop and tell the human**: they must run `hexaeight-activate newtoken`
themselves, which needs a licence code and a QR approval from the HexaEight Authenticator app. You
cannot do this for them.

If they exist in one directory but not the others, **hardlink** them — never copy:

```bash
mkdir -p ~/hbia-router ~/hbia-workspace
ln ~/hbia-agent/env-file      ~/hbia-router/env-file
ln ~/hbia-agent/hexaeight.mac ~/hbia-router/hexaeight.mac
ln ~/hbia-agent/env-file      ~/hbia-workspace/env-file
ln ~/hbia-agent/hexaeight.mac ~/hbia-workspace/hexaeight.mac
```

A **copy** of `hexaeight.mac` is a second machine binding and will not verify. A copied `env-file`
goes stale the moment the licence is renewed. Hardlinks share one file, so both stay correct.

**Check:**

```bash
cd ~/hbia-agent && hexaeight-activate verify-env
```

Must say the licence is installed and working, and print an identity name. **Write that name
down — you need it in step 5.**

---

## 2. The tool

```bash
dotnet tool install --global HexaEight.Activate || dotnet tool update --global HexaEight.Activate
export PATH="$HOME/.dotnet:$HOME/.dotnet/tools:$PATH"
hexaeight-activate help
```

**Check:** `help` lists `install-router`, `upstreams`, `models`, `engine`, `sandbox`,
`install-workspace`.

**Check the version — 1.0.32 or newer:**

```bash
dotnet tool list -g | grep -i hexaeight.activate
```

Older tools cannot do step 5 in one pass: `engine --auto` does not exist before 1.0.32, and
`install-agent` does not fetch the `harness` and `mindmapchat` engines. If the version is older and
`dotnet tool update` did not move it, the `||` above short-circuited — run the update on its own:

```bash
dotnet tool update --global HexaEight.Activate
```

### A DIFFERENT PROGRAM MAY OWN THIS NAME — check before you trust it

An unrelated, obsolete npm package (`@hexaeight/sdk`) installs commands with the **same names**:
`hexaeight-activate`, `hexaeight-renew`, `hexaeight-verify-env`, usually at `/usr/local/bin`. It is
**not** the tool this guide uses and it cannot do anything described here.

**How you will notice:** `hexaeight-activate help` prompts for a *"Resource Name"* instead of
listing subcommands. If that happens, you are running the wrong program.

**Check which one is on PATH:**

```bash
command -v hexaeight-activate
```

- Under `~/.dotnet/tools/` → correct, carry on.
- Anywhere else (`/usr/local/bin`, `/usr/bin`) → it is the npm one, and it is shadowing the tool
  you just installed.

**Do not use it, do not `newtoken` with it, and do not report its output as a failure of this
guide.** Do not uninstall it either — it is not yours to remove, and other things may reference it.

Simply put the .NET tool first and confirm:

```bash
export PATH="$HOME/.dotnet:$HOME/.dotnet/tools:$PATH"
command -v hexaeight-activate      # must now be under ~/.dotnet/tools
hexaeight-activate help | head -5  # must list subcommands, not ask for a Resource Name
```

**Export that PATH in every shell you use for the rest of this install.** A new SSH session, a
`sudo` command, or a script that resets the environment will silently pick the npm one again. If you
would rather not depend on ordering at all, call it by absolute path throughout:

```bash
~/.dotnet/tools/hexaeight-activate help
```

That is unambiguous and cannot be shadowed. Mention to the human that the old npm package is still
installed and no longer used, so they can remove it themselves when convenient.

---

## 3. Router, and a provider key

```bash
cd ~/hbia-router
hexaeight-activate install-router
hexaeight-activate upstreams
```

`upstreams` asks which provider, a tag, a region if the provider has one, which dialects, and the
API key. **Ask the human for the key** — do not invent one, and do not proceed without it.

Route names are `*-<dialect>-<tag>`: dialect is `ant` (Anthropic), `oai` (OpenAI) or `res`
(Responses); the tag names one provider **and one key**.

**Check — this is the step people skip, and it is the cheapest possible way to find a dead key:**

```bash
hexaeight-activate models --filter claude
```

It must list model ids. `HTTP 403` or `401` means the key is rejected: **stop and ask for a new
one**. Everything after this point will appear to work and then fail at the first real turn.

**Now show the human the list and ask which model they want.** Run it without `--filter` so they see
everything the key can reach:

```bash
hexaeight-activate models
```

Ask plainly: *"Your key can reach these models — which should the agent use?"* Record their answer
exactly as printed; that string is the provider's model id and you need it verbatim in step 5. Do
not choose one yourself, and do not shorten it.

**THE LIST IS THE ONLY EVIDENCE. Do not reason about who made a model.** One provider hosts many
vendors' models: a Bedrock key typically reaches `anthropic.claude-*`, `zai.glm-*`,
`moonshotai.kimi-*`, `openai.gpt-oss-*`, `qwen.*` and `deepseek.*` all at once. So "GLM is a z.ai
model, therefore it is not on this Bedrock route" is **wrong reasoning** — if `zai.glm-5` appears in
the output, that route serves it. If it does not appear, it is not reachable, whoever made it.

### If they want a model this key cannot reach

That is not a failure and not something to talk them out of. It means a **second provider**, which
is one more run of the same command:

```bash
hexaeight-activate upstreams
```

Pick that provider, give it its **own tag** (the tag names one provider *and* one key), and ask the
human for **that provider's key** — a Bedrock key does not work at z.ai. Then re-check with
`hexaeight-activate models --tag <newtag>` and use one of *its* routes in step 5.

Both providers coexist; nothing is replaced. An agent can have engines on different providers, and
a route name is what selects between them.

### The split decision — why a route name is not a model name

The engine sends **one** string that does two jobs, separated by `|`:

```
claude-ant-aws|us.anthropic.claude-sonnet-4-20250514-v1:0
└── route ──┘ └────────────── model ──────────────────┘
```

- **The left half chooses the upstream.** The router globs it against each entry's `match` and
  `shape`. That is how it knows *which provider and which key* to use — `…-aws` and `…-zai` are
  different destinations even for the same model family.
- **The right half is what the provider is asked for**, sent verbatim. It must be a real model id
  from the `models` output.

This is why a route name never has to be a real model name, and why you cannot swap them. A common
mistake is putting a model id on the left (it then matches no route → HTTP 503) or a route name on
the right (the provider has never heard of it → 404 from the provider).

To use a different model on the same provider later, only the right half changes. To use a different
*provider*, the left half changes to one of that provider's routes.

Start it:

```bash
cd ~/hbia-router && nohup ./hexaeight-router-* > router.log 2>&1 &
sleep 20 && grep -aE "License|Loaded|listening" router.log
```

**Check:** `License verification: StandardLicense`, `Loaded N upstream(s)`, and listening on 5100.
**Note the identity name the router prints** — that is the router's agent name for step 5.

---

## 4. Agent

```bash
cd ~/hbia-agent
hexaeight-activate install-agent
```

This writes `hexaeight-agent.json` with the keys that matter, including `llmPort` (without it no
engine can reach a model) and `loadDependencies` (without it Node-RED is declared but never hosted).

It also installs everything the engines need, so step 5 has binaries to point at:

- the pinned toolchain, including the Claude CLI version engines are known to work with
- the `harness` and `mindmapchat` engines, downloaded from the same release as the agent and
  verified by SHA-256 the same way

**Check:** the last lines mention both engines. A `SKIPPED` or a failure here is not fatal to the
install — the agent is already verified — but step 5 will report that engine as missing, so re-run
this command rather than continuing without it.

**Check the sandbox before starting the agent:**

```bash
hexaeight-activate sandbox
```

- `WORKING` — good.
- `NOT INSTALLED` — turns run **unconfined**, with write access to the folder holding `env-file` and
  `hexaeight.mac`. On Linux `install-agent` already tried `sudo -n apt-get install -y bubblewrap`; if
  it is still missing, sudo needed a password. Run it yourself:
  `sudo apt-get install -y bubblewrap`. (macOS never hits this — see the platform note.)
- `INSTALLED BUT CANNOT RUN` — **this is the dangerous one.** The agent picks its sandbox by
  existence, so it will wrap every spawn in something that fails, and every turn dies with "the
  engine exited without replying". This is the Ubuntu 24.04 case: the package installs cleanly and
  AppArmor still blocks unprivileged user namespaces, which is why only actually running it catches
  the problem. Follow the fix it prints, or remove bubblewrap. **Do not start the agent in this
  state.**

### macOS ONLY — narrow the jail mask, or no turn will ever answer

**Do this on macOS before the first turn. Skipping it produces a working-looking install in which
every engine dies instantly**, with the same "the engine exited without replying" as a dozen other
causes.

By default the jail hides the agent's **whole current directory** — which is the licence folder — so
that an engine cannot read `env-file` or `hexaeight.mac`. On Linux the engine is moved out of that
folder before it starts, so it never notices. **On macOS it is not moved**, so it starts inside a
directory it is forbidden to read and dies immediately with `EPERM`.

Mask the credential **files** instead of the folder. Same protection, and the engine can start:

```bash
cd ~/hbia-agent
cp hexaeight-agent.json hexaeight-agent.json.bak_$(date +%Y%m%d_%H%M%S)
python3 - <<'PY'
import json, os
p = 'hexaeight-agent.json'
d = json.load(open(p))
# BOTH path forms. macOS reaches one directory by two names through a firmlink
# (/Users/... and /Volumes/Macintosh_HD/Users/...). One entry is enough in practice — the
# sandbox resolves to the real file — but listing both costs nothing and survives a layout change.
mask = sorted(os.path.join(b, f)
              for b in {os.path.realpath('.'), os.path.abspath(os.path.expanduser('~/hbia-agent'))}
              for f in ('env-file', 'hexaeight.mac', 'agent.uuid'))
d['jail'] = {'enabled': True, 'mask': mask}
json.dump(d, open(p, 'w'), indent=2)
print(json.dumps(d['jail'], indent=1))
PY
```

Restart the agent, then **prove both halves** — the engine can start, and the credentials are still
hidden. Build the profile exactly as the agent does and test it:

```bash
cd ~/hbia-agent
M=$(python3 -c "import json;print(' '.join('(subpath \"%s\")'%m for m in json.load(open('hexaeight-agent.json'))['jail']['mask']))")
P="(version 1)(allow default)(deny file-read* $M)"
/usr/bin/sandbox-exec -p "$P" ~/.heia/runtime/node_modules/.bin/claude --version   # must print a version
/usr/bin/sandbox-exec -p "$P" /bin/cat env-file                                    # must say Operation not permitted
```

**A version plus an `Operation not permitted` is the pass.** A version with a readable `env-file`
means the mask is wrong and the engine can read the licence — stop and fix it. `EPERM` from the
first command means the mask still covers the whole folder.

Note this is narrower than the Linux default: the engine can read other files in that folder
(`sessions.he`, `engines.he`), which are encrypted at rest. The credentials themselves are not
readable, which is what the mask is for.

---

## 5. Point the engines at the router

Every install gets **three** engines. Seal them in one pass:

```bash
cd ~/hbia-agent
hexaeight-activate engine --auto
```

| engine | what it is |
|---|---|
| `claude` | the pinned Claude Code CLI |
| `harness` | a drop-in for `claude -p` — same flags, same stream-json frames |
| `mindmapchat` | the same loop plus the fact ledger, captured procedures and the mind map |

It asks **three** things, once, and applies them to all three engines:

| asked | answer |
|---|---|
| route | **an `anthropic`-shaped route** — see the rule below. Getting this wrong is the #1 way to end up with an install that looks finished and cannot answer |
| provider's model id | the id `models` printed, e.g. `us.anthropic.claude-sonnet-4-20250514-v1:0` |
| router | `<router identity name>\|http://127.0.0.1:5100` |

#### THE ROUTE MUST BE ANTHROPIC-SHAPED. This is not a preference.

**All three engines speak the ANTHROPIC dialect** — they are Claude-CLI-shaped programs. The router
picks an upstream by matching **both** the route glob **and** the dialect. Hand these engines a route
whose `shape:` is anything else and there is no working combination: the turn dies at the provider,
not at the router, with an error that never mentions dialects. A real one:

```
API Error: 400 [1214][modelCode: does not exist]
```

That reads like a wrong model id. It is not — it is the right model sent to the wrong kind of
endpoint. Nothing upstream of it says so.

**Read the routes and pick by `shape`, never by the name:**

```bash
grep -A2 'match:' ~/hbia-router/upstreams.yaml
```

```yaml
  - match:     "*-ant-aws"        # shape: anthropic  <-- USE THIS ONE
    shape:     "anthropic"
  - match:     "*-oai-aws"        # shape: openai     <-- NOT for these engines
    shape:     "openai"
```

The `-ant-` / `-oai-` in a route name is a **convention that encodes the dialect**, not decoration.
`glm-ant-aws` and `glm-oai-aws` can point at the same provider and the same key and still be
completely different routes. If both exist, these engines take the `-ant-` one.

**If no route has `shape: anthropic`, stop.** Do not seal an engine against an openai route and hope.
Add an anthropic upstream first (`hexaeight-activate upstreams`, step 3), then come back.

The model field becomes `<route>|<model id>`: the router globs the left half to pick an upstream and
sends the right half to the provider. That is why a route name never has to be a real model id.

Binaries are not asked for. All three come from the pinned copies under `.heia/runtime` that step 4
installed — never from whatever is on `PATH`.

Non-interactive (an installer that already knows the answers):

```bash
hexaeight-activate engine --auto \
  --route claude-ant-aws \
  --model us.anthropic.claude-sonnet-4-20250514-v1:0 \
  --router "<router identity name>|http://127.0.0.1:5100"
```

**If an engine says SKIPPED**, its binary is missing — the message names the path it looked for.
`claude` comes from `install-runtime`; `harness` and `mindmapchat` come from `install-agent`. Re-run
whichever it names; do not seal around it.

Bare `hexaeight-activate engine` (no `--auto`) still exists for a *non-standard* engine — codex, an
OpenAI-shaped CLI, something with its own binary. It asks the longer set of questions, once per
engine. You do not need it for a normal install.

**Check — all three, not just one:**

```bash
./hexaeight-agent-* export --plaintext --out /tmp/e.json && \
python3 -c "import json;d=json.load(open('/tmp/e.json'));\
[print(f\"{n:12} file={e['file'].split('/')[-1]:20} approve={e['approve']} \
skills={list(e.get('skills',{}).keys())} model={e['proxy']['model']}\") \
for n,e in d.items()]" && rm /tmp/e.json
```

Every row must show `approve=False`, `skills=['dir','priming']`, and a model containing `|`.
**If `skills` is missing on any engine, that engine has no skill tools at all** — and the only
symptom will be a later failure saying one specific tool is unavailable.

**And check the dialect actually agrees** — the check that would have caught the failure above:

```bash
ROUTE=$(./hexaeight-agent-* export --plaintext --out /dev/stdout 2>/dev/null \
        | python3 -c "import json,sys;print(json.load(sys.stdin)['claude']['proxy']['model'].split('|')[0])")
echo "engines are sealed to route: $ROUTE"
python3 - "$ROUTE" <<'PY'
import re, sys, glob
route = sys.argv[1]
for f in glob.glob('/'.join(__import__('os').path.expanduser('~/hbia-router/upstreams.yaml').split('/'))):
    txt = open(f).read()
for m, s in re.findall(r'match:\s*"([^"]+)"\s*\n\s*shape:\s*"([^"]+)"', txt):
    if re.fullmatch(m.replace('*', '.*'), route):
        print(f"  matches upstream {m} with shape={s}")
        print("  OK — anthropic" if s == "anthropic"
              else f"  WRONG — these engines speak anthropic, this route is {s}. Re-run engine --auto with an anthropic route.")
        break
else:
    print("  NO UPSTREAM MATCHES THIS ROUTE — every turn will fail. Fix step 3 or re-run engine --auto.")
PY
```

It must say **OK — anthropic**. Anything else means the turns will fail at the provider with a
message that does not mention routing.

The workspace lists only engines the agent actually serves, so if one is missing here it will simply
not appear in the UI later. That is the intended behaviour, not a UI fault.

### CHECK FOR A PERSONAL CLAUDE CONFIG — it silently takes the claude engine off the router

**Run this check. Do not change anything yet — the answer is the human's to give.**

```bash
python3 - <<'PY'
import json, os
p = os.path.expanduser('~/.claude/settings.json')
if not os.path.exists(p):
    print('clean - no ~/.claude/settings.json'); raise SystemExit
env = json.load(open(p)).get('env', {})
hit = {k: v for k, v in env.items() if 'ANTHROPIC' in k.upper() and 'URL' in k.upper()}
print(f'FOUND in {p}:') if hit else print('clean - no ANTHROPIC url set there')
for k, v in hit.items(): print(f'   {k} = {v}')
PY
```

**If it says clean, skip this section entirely.**

**If it found one, stop and tell the human this, in these terms:**

> Your personal Claude Code is configured to send requests to `<the url>`. The Claude CLI applies
> that file's settings **over** anything HBIA passes it, so the `claude` engine here will ignore the
> router and send turns straight to that address — no routing, no policy, no per-turn nonce, and the
> key in that file gets spent directly. It shows up as `400 modelCode: does not exist`, which looks
> like a wrong model and is not.
>
> Nothing in HBIA can override it. `CLAUDE_CONFIG_DIR`, `--settings` and overriding `HOME` were all
> tried and none of them move it — the CLI resolves that file from your OS user record.
>
> I can move those two keys out of `~/.claude/settings.json` and into your shell profile instead.
> Your own `claude` keeps working exactly as now; HBIA's engine never sees a shell, so it gets the
> router. **Shall I?**

**Then wait. Do not edit that file without a yes.** It is their personal setup, not part of this
install.

**If they say yes:**

```bash
cp ~/.claude/settings.json ~/.claude/settings.json.bak_$(date +%Y%m%d_%H%M%S)
python3 - <<'PY'
import json, os
p = os.path.expanduser('~/.claude/settings.json')
d = json.load(open(p)); env = d.get('env', {})
moved = {k: env.pop(k) for k in list(env)
         if k.upper() in ('ANTHROPIC_BASE_URL', 'ANTHROPIC_AUTH_TOKEN')}
d['env'] = env; json.dump(d, open(p, 'w'), indent=2)
rc = os.path.expanduser('~/.zshrc' if os.environ.get('SHELL','').endswith('zsh') else '~/.bashrc')
with open(rc, 'a') as f:
    f.write('\n# personal claude. NOT in ~/.claude/settings.json - that file overrides the\n')
    f.write('# environment and would send HBIA engine turns here too, bypassing the router.\n')
    for k, v in moved.items(): f.write(f'export {k}={v}\n')
print('moved to', rc, ':', list(moved))
PY
```

Tell them to run `source ~/.zshrc` in any terminal already open — existing shells do not pick it up
on their own, and their personal `claude` will look broken until they do.

**If they say no, that is a fine answer.** Say plainly what it costs and carry on:

> Then the `claude` engine will not work here, and I will leave it configured but unusable.
> **`harness` and `mindmapchat` are unaffected** — they are HexaEight's own engines, they honour the
> address HBIA gives them, and they go through the router correctly. Use those. The rest of the
> install is unchanged.

Do not argue the point, and do not quietly edit the file anyway.

### Adding another engine later

`engine --auto` only ever handles the three standard ones, and re-running it is safe — it re-seals
them in place.

**Those three are the whole set this install provides. Do not add others uninvited.** Codex, grok,
llxprt and the framework engines are **not shipped and not installed** — HBIA does not put them on
the machine and there is nothing to point an engine at. If the human has installed one themselves
and asks for it, wire it up; otherwise finish with the three and say so.

For such an engine, use the interactive form, one at a time:

```bash
cd ~/hbia-agent && hexaeight-activate engine
```

It asks for the binary's absolute path — which must already exist — and the same dialect rule
decides the route: **pick the route whose `shape` matches what that engine speaks** — anthropic for
Claude-shaped, openai for OpenAI-shaped, responses for Codex. The interactive command lists only the
routes serving the dialect you chose and warns when none does. Restart the agent afterwards; engines
are read at startup.

Start the agent:

```bash
cd ~/hbia-agent && nohup ./hexaeight-agent-* > agent.log 2>&1 &
sleep 40 && grep -aiE "engine '|LLM listener|licence|services" agent.log | head
```

**Check:** `engine 'claude' -> process`, `LLM listener on 127.0.0.1:8899`, and node-red `ready`.

---

## 6. Workspace

```bash
cd ~/hbia-workspace
hexaeight-activate install-workspace --agent <agent identity name from step 1>
```

**Check:** it reports `browser auth … MB` (the WASM runtime) and writes a deployment config naming
your agent.

**Check the bundle is new enough to KNOW your engines.** The rail can only list an engine whose name
is compiled into the bundle. An older bundle omits `harness` and `mindmapchat` entirely, so they are
sealed, served, and simply never appear — with nothing on screen to say why:

```bash
cd ~/.heia/runtime/workspace
for e in claude harness mindmapchat; do
  printf '  %-12s %s\n' "$e" "$(grep -rlo "$e" assets/*.js 2>/dev/null | wc -l) asset file(s)"
done
```

Each must be **1 or more**. A `0` for `harness` or `mindmapchat` means the deployed bundle predates
them — re-run `hexaeight-activate install-workspace` to fetch the current one, and if it still shows
`0`, the machine is pinned to an old release rather than misconfigured.

Serve it:

```bash
cd ~/.heia/runtime/workspace && nohup node serve.mjs --port 5620 --host 127.0.0.1 > ws.log 2>&1 &
```

**HTTPS is required unless the browser is on this same machine.** Not advice — two browser rules
make plain HTTP fail:

- browser sign-in signs with WebCrypto, which does not exist outside a secure context: login dies
  with `Cannot read properties of undefined (reading 'sign')`;
- a page served over plain HTTP may not fetch `localhost` at all, so the agent is unreachable even
  while running.

Put a certificate in front of it (Caddy, nginx), or tunnel it. If the browser **is** on this
machine, `http://localhost:5620` is a secure context and works as-is.

### Or host it as a static site instead

**The workspace is plain static files** — `index.html`, `assets/`, `bootsharp/`, `config.js`.
`serve.mjs` is a convenience, not a requirement. Ask the human whether they would rather host it on
something they already have (S3 + CloudFront, Netlify, GitHub Pages, an existing nginx). Often they
would, and then no tunnel is needed for the UI at all.

To do that, copy the directory to the host and **edit `config.js` there**:

```js
window.__HEIA_CONFIG = {
  agent: 'their-agent-name.example.com',   // the identity from step 1
  localWorkspace: false,                   // reach the agent by name, via the registry
  localAgentPort: null,
  agentLocalUrl: '',
};
```

Three things that must hold, or it will fail in ways that look unrelated:

- **The site must be HTTPS.** Same two browser rules as above — no exceptions.
- **`localWorkspace: false`.** The browser is not on the agent's machine, so it must resolve the
  agent by name rather than reach for `localhost`.
- **The agent still needs to be publicly reachable and registered** — see step 6b. Hosting the UI
  statically removes the workspace's tunnel, not the agent's.

**It can be any host, and you should help them set it up rather than hand them files.** Ask what
they already have, then do the work with them. There is no build step and nothing machine-specific
in the bundle, so it is genuinely just files plus a correct `config.js`. Some starting points:

```bash
# nginx / Apache on this machine or another
sudo cp -r ~/.heia/runtime/workspace/* /var/www/hbia/
# then a server block for /var/www/hbia with TLS (certbot, or a certificate they already have)

# S3 + CloudFront
aws s3 sync ~/.heia/runtime/workspace/ s3://their-bucket/ --delete
# CloudFront in front of it gives HTTPS; set index.html as the default root object

# Netlify / Vercel / Cloudflare Pages
netlify deploy --dir ~/.heia/runtime/workspace --prod      # HTTPS included

# GitHub Pages
# commit the directory to a repo, enable Pages on that branch — HTTPS included
```

Whatever they choose, do these three things with them and check each one:

1. **Copy the whole directory**, not selected files — `bootsharp/` is ~56 MB of WASM and sign-in
   fails without it. Confirm `bootsharp/dotnet/dotnet.js` is reachable on the deployed site.
2. **Edit `config.js` on the host** with their agent name and `localWorkspace: false`. Fetch it back
   and read it to confirm it deployed — a cached old copy is a common and confusing failure.
3. **Load the site and check the browser console.** `reading 'sign' of undefined` means it is not
   being served over HTTPS.

If they have no host and no preference, the tunnel in step 6b is the quickest thing that works;
offer that instead of leaving them stuck.

Upgrading later means copying a newer bundle and keeping their `config.js`.

---

## Restarting a component — read this before you do it

Several steps need a restart. Do it this way; the obvious way has three traps and you will hit all
of them.

**NEVER MATCH ON THE COMMAND LINE.** Any `-f` pattern containing the binary's name also matches
*your own shell*, because your command line contains that string too. `pkill -f` kills your session
(exit 144) and leaves the agent running; a `pgrep -f` kill-loop does the same thing one step later.
Both have happened here, in consecutive attempts.

**Target the PORTS instead.** A port is held by exactly one process, your shell holds none of them,
and it works the same on Linux and macOS.

```bash
# The agent's own ports. NOT 5100 (router) or 5620 (workspace) - those stay up.
PORTS="8770 8899 8902 8904 8907 1880"

# 1. Stop whatever holds them. lsof is present on both Linux and macOS.
for p in $PORTS; do
  pids=$(lsof -ti tcp:"$p" 2>/dev/null) && [ -n "$pids" ] && kill -9 $pids 2>/dev/null
done
sleep 3

# 2. CONFIRM they are free. A survivor holds 8770 and the replacement then aborts with
#    "address already in use", which reads as a broken install rather than a stale process.
for p in $PORTS; do
  lsof -ti tcp:"$p" >/dev/null 2>&1 && echo "  STILL BUSY: $p" || echo "  free: $p"
done

# 3. And confirm the two you did NOT touch are still serving.
for p in 5100 5620; do
  lsof -ti tcp:"$p" >/dev/null 2>&1 && echo "  still up: $p" || echo "  DOWN: $p"
done
```

If `lsof` is missing, Linux has `fuser -k 8770/tcp 8899/tcp …` and `ss -ltn` to verify. On macOS
`lsof` is always present. **Do not fall back to `pkill -f`.**

# 3. TRUNCATE THE LOG. agent.log is appended across boots, so lines from the previous run sit above
#    the new ones and read as current. An installer spent four steps deciding whether
#    "[register] disabled" was from this boot or the last one. Truncating makes the log say only
#    what just happened.
cd ~/hbia-agent && : > agent.log

# 4. Start detached, so it survives your shell ending.
setsid ./hexaeight-agent-linux-x64 > agent.log 2>&1 < /dev/null &
disown
sleep 40
```

Then verify it is **the new process** — not the old one you meant to replace:

```bash
ps -o pid,lstart,comm -p "$(lsof -ti tcp:8770 | head -1)"
```

The start time must be seconds ago. `lstart` is on both Linux and macOS.

Same approach for the others: the **router** holds 5100, the **workspace** holds 5620. Stop one by
freeing its port, never by name.

The start time must be seconds ago. The same procedure applies to the router
(`hexaeight-router-linux-x64`) and the workspace (`serve.mjs --port`).

**A config change needs a restart to take effect.** Editing `hexaeight-agent.json` or re-sealing an
engine changes nothing in a running agent — engines are read at startup, and "engines load live"
adds new ones without rebuilding an existing one. If a change appears to have been ignored, it was:
the agent is still running the previous definition.

---

## 6b. Remote access — only if the human wants it

**Skip this entirely if the browser is on this machine.** `http://localhost:5620` is a secure
context and everything works with no tunnel, no certificate and nothing exposed.

Ask first: *"Do you need to reach this from another machine or a phone?"* If no, skip.

If yes, **both** the agent and the workspace need to be reachable over HTTPS, for different reasons:
the agent because the browser and the mobile app talk to it, the workspace because WebCrypto and
loopback-fetch rules make plain HTTP unusable.

**Install cloudflared** — it is a system binary, not an npm package.

**Prefer a LOCAL install (`~/bin`) and do not fight for a system-wide one.** A managed or corporate
machine often refuses `sudo mv` into `/usr/local/bin`, or has no Homebrew, and that refusal is not
worth working around: a binary in the user's own `~/bin` works exactly as well, because the agent is
told the **absolute path** below rather than searching `PATH`.

```bash
mkdir -p ~/bin

# macOS (Apple Silicon)
curl -sL -o ~/bin/cloudflared \
  https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-arm64.tgz
tar -xzf ~/bin/cloudflared -C ~/bin && rm -f ~/bin/cloudflared.tgz 2>/dev/null

# Linux x64
curl -sL -o ~/bin/cloudflared \
  https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64

chmod +x ~/bin/cloudflared
~/bin/cloudflared --version
```

Homebrew (`brew install cloudflared`) and a system-wide install are both fine if they work — the
point is only that a local one is enough, so a blocked `sudo` is not a blocker.

**THE AGENT DOES NOT SEARCH YOUR SHELL'S `PATH`.** It runs as a daemon with its own environment, and
`~/bin` is almost never on it. Installing to `~/bin` and stopping there produces exactly this, with
everything else looking healthy:

```
[reach] cloudflared could not start (... No such file or directory)
[register] SKIPPED - nothing to publish
```

`register SKIPPED` means the agent never publishes its URL, so it **cannot be resolved by name** —
the workspace can only reach it if you happen to have a tunnel up by hand. So whenever cloudflared
is not on a system path, name it explicitly in the next step with `"bin"`.

**Point the agent at it.** Installing the binary is not enough — the agent must be told to use it,
and to publish the resulting URL:

```bash
cd ~/hbia-agent
python3 - <<'PY'
import json, os, shutil
p = 'hexaeight-agent.json'
d = json.load(open(p))
# THE ABSOLUTE PATH, ALWAYS. Found here, where a login shell's PATH is available; the agent's
# own environment will not have ~/bin on it, and "cloudflared" alone fails with
# "No such file or directory" while the binary sits happily in the user's home.
binpath = shutil.which('cloudflared') or os.path.expanduser('~/bin/cloudflared')
if not os.path.exists(binpath):
    raise SystemExit(f"cloudflared not found at {binpath} - install it first, then re-run this")
d['reach'] = {'mode': 'cloudflared', 'bin': binpath}   # starts its own tunnel, publishes that URL
d['register'] = True                                   # and lists it, so it resolves by NAME
json.dump(d, open(p, 'w'), indent=2)
print(json.dumps({k: d[k] for k in ('reach', 'register')}, indent=1))
PY
```

Restart the agent, then check:

```bash
grep -aE "reach|register" ~/hbia-agent/agent.log | tail -3
```

**Success:** `mode=cloudflared tunnel up https://….trycloudflare.com` and `[register] OK`. A
`register FAILED … url must be a clean https URL` means the tunnel did not start and it published a
LAN address instead.

**Tunnel the workspace too**, as a separate tunnel:

```bash
nohup cloudflared tunnel --url http://127.0.0.1:5620 > /tmp/ws-tunnel.log 2>&1 &
sleep 15 && grep -oaE 'https://[a-z0-9-]+\.trycloudflare\.com' /tmp/ws-tunnel.log | head -1
```

Give the human **that** URL — not the `:5620` one.

**NOW STOP THE WORKSPACE REACHING FOR `localhost` — the tunnel is not finished without this.**

`install-workspace` configures the UI for a browser sitting on this machine. Through a tunnel the
browser is somewhere else entirely, so `localhost` is the *human's own laptop*, not this server. The
page loads, sign-in may even work, and then every call to the agent fails against a machine that was
never running one. Nothing on screen says "wrong host".

Edit `config.js` in the served directory (the one `serve.mjs` runs from):

```bash
cd ~/.heia/runtime/workspace
cp config.js config.js.bak_$(date +%Y%m%d_%H%M%S)
python3 - <<'PY'
import re
p = 'config.js'
s = open(p).read()
s = re.sub(r"localWorkspace:\s*[^,]+",  "localWorkspace: false", s)
s = re.sub(r"localAgentPort:\s*[^,]+",  "localAgentPort: null",  s)
s = re.sub(r"agentLocalUrl:\s*[^,]+",   "agentLocalUrl: ''",     s)
open(p, 'w').write(s)
print(s)
PY
```

It must end up with the agent reached **by name**, and every local shortcut emptied:

```js
window.__HEIA_CONFIG = {
  agent: 'their-agent-name.example.com',   // the identity from step 1 - must NOT be blank
  localWorkspace: false,                   // resolve via the registry, never localhost
  localAgentPort: null,
  agentLocalUrl: '',
};
```

**Check:** reload the tunnel URL with the browser console open. No request to `localhost` or
`127.0.0.1`, and no mixed-content warning. If `agent` is blank the UI has nothing to resolve and
sign-in fails with no useful message — that value comes from step 1, not from the tunnel.

This applies to **any** remote path — a tunnel, a certificate in front of it, or static hosting. The
rule is simply: if the browser is not on this machine, the workspace must not reach for `localhost`.

**Tell them this, because it will bite otherwise:** a quick tunnel gets a **new hostname every time
it restarts**. The agent re-registers itself, so resolving it by name keeps working — but any URL
someone bookmarked dies. For anything permanent, use a named Cloudflare tunnel (needs a Cloudflare
account) or a real DNS name plus a certificate, and set `reach` to
`{"mode": "custom", "url": "https://your-stable-host"}`.

---

## 7. Prove it end to end

Open the workspace, sign in with the agent name and the human's email, and send one message.

**The rail lists only engines this agent actually serves.** You should see `claude`, `harness` and
`mindmapchat`. An engine missing here was not sealed in step 5 — go back and check its row rather
than looking for a UI fault. An engine you never configured is *supposed* to be absent.

```bash
grep -aE "as .*via" ~/hbia-router/router.log | tail -2
```

**Success looks like:**

```
[/v1/messages] someone@example.com → claude-ant-aws as 'us.anthropic.claude-sonnet-4-…'
               via https://bedrock-runtime.us-west-2.amazonaws.com
```

Left of `as` is the route; right is what the provider was actually asked for.

---

## 7b. Survive a reboot — do this before you hand over

Everything you started above was launched by hand with `nohup`. **None of it comes back after a
restart.** The human reboots, opens the URL you gave them, and finds nothing — which reads as an
install that never worked rather than one that was never made persistent.

```bash
hexaeight-activate autostart on
hexaeight-activate autostart status
```

This writes **launchd agents** on macOS (`~/Library/LaunchAgents`) and **systemd --user** units on
Linux, and it encodes the ordering the components actually need: the router first, the agent once
`:5100` answers, the workspace once `:8770` does. That ordering cannot be expressed in launchd, so
it is enforced by waiting for the port rather than by a sleep that guesses — which is why this is a
command and not three plist files you write yourself.

**Check:** `autostart status` lists all three as loaded. Then prove it for real — this is the only
check that means anything:

```bash
sudo reboot        # or have the human reboot
# after it comes back, from a fresh shell:
hexaeight-activate autostart status
for p in 5100 8770 5620; do
  (echo > /dev/tcp/127.0.0.1/$p) 2>/dev/null && echo "  $p up" || echo "  $p DOWN"
done
```

On Linux, `systemd --user` units only run while that user has a session unless lingering is enabled.
If the ports are down after a reboot on a headless box, that is the cause:

```bash
sudo loginctl enable-linger "$USER"
```

To undo any of this: `hexaeight-activate autostart off` (leaves running processes alone), or see
UNINSTALL.md.

---

## 8. FINISH BY HANDING OVER THE URL

An install is not delivered until the human knows where to click. Do not end with "the workspace is
running on port 5620" — that is a fact about your terminal, not an address they can open. Print the
**one URL they should use**, and say plainly which it is:

```bash
# The tunnel URL, when there is one (step 6b) — this is the one to give them.
grep -oaE 'https://[a-z0-9-]+\.trycloudflare\.com' /tmp/ws-tunnel.log 2>/dev/null | tail -1
# Otherwise, only if their browser is on THIS machine:
echo "http://localhost:5620"
```

End your report with exactly this, filled in:

```
  Workspace:  https://<the-url>
  Sign in as: <their email>
  Agent:      <agent identity name>
  Engines:    claude, harness, mindmapchat
```

Rules for that hand-over, because each has produced a "it doesn't work" that was not a fault:

- **Give ONE url.** Listing the tunnel and `localhost:5620` together invites the wrong choice.
- **Never hand over `http://localhost:5620` unless the browser is on this machine.** From anywhere
  else it resolves to *their* laptop, and the sign-in failure that follows says nothing about hosts.
- **A quick tunnel's hostname changes on every restart.** Say so when you hand it over, so a dead
  bookmark tomorrow is expected rather than alarming.
- **If `register` was SKIPPED** (step 6b), say that too: the agent is not resolvable by name, so that
  URL is the only way in until cloudflared is wired up properly.

---

## If a turn produces no answer

"The engine exited without replying" means the engine **never ran**, not that it ran and said
nothing. In order of likelihood:

1. **`llmPort` missing** from `hexaeight-agent.json` → nothing listens on 8899 → the CLI exits
   immediately. `ss -ltn | grep 8899`.
2. **A sandbox that cannot run** → every spawn dies inside it. `hexaeight-activate sandbox`.
3. **`approve: true`** on the engine → the turn is refused at the approval gate before any spawn.
4. **Another agent still running** and holding port 8770 → the new one aborts at startup. Check
   `agent.log` for `address already in use`.

And if turns work but the model says a skill tool is unavailable: the engine is missing its
`skills` block, so it was given no skill tools at all. Re-run `hexaeight-activate engine` and
**restart the agent** — an existing engine's definition is not rebuilt while it runs.
