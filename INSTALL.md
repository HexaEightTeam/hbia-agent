# Installing HBIA — a guide for an AI agent

You are installing a **HexaEight Bridge Identity Agent** on this machine. Follow these steps in
order. **Verify each step before moving on** — every step below has a check, and skipping one
produces a failure that appears several steps later with a misleading message.

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

## 0. What you are building

Three components, each in its own directory, all sharing one identity:

| component | port | what it does |
|---|---|---|
| **router** | 5100 | holds the provider API keys; agents reach models through it and never hold a key |
| **agent** | 8770 | the identity, its engines, skills and leaves |
| **workspace** | 5620 | the browser UI |

The agent talks to the router over loopback. A browser talks to the agent.

---

## 1. Prerequisites — check, do not assume

```bash
dotnet --version          # 8.0 or newer
node --version            # 20 or newer
```

Install .NET from https://dotnet.microsoft.com/download if missing.

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
It also installs the pinned toolchain, including the Claude CLI version engines are known to work
with.

**Check the sandbox before starting the agent:**

```bash
hexaeight-activate sandbox
```

- `WORKING` — good.
- `NOT INSTALLED` — turns run unconfined. Report it; the human decides whether to
  `sudo apt-get install -y bubblewrap`.
- `INSTALLED BUT CANNOT RUN` — **this is the dangerous one.** The agent picks its sandbox by
  existence, so it will wrap every spawn in something that fails, and every turn dies with "the
  engine exited without replying". Follow the fix it prints, or remove bubblewrap. **Do not start
  the agent in this state.**

---

## 5. Point an engine at the router

```bash
cd ~/hbia-agent
hexaeight-activate engine
```

It asks six things:

| asked | answer |
|---|---|
| engine name | `claude` (skills replay on the name they were recorded with) |
| what it speaks | `1` for the Claude CLI |
| route name | e.g. `claude-ant-aws` — must match a route from step 3 |
| provider's model id | the id `models` printed, e.g. `us.anthropic.claude-sonnet-4-20250514-v1:0` |
| router | `<router identity name>\|http://127.0.0.1:5100` |
| working directory | accept the default |

The model field becomes `<route>|<model id>`: the router globs the left half to pick an upstream and
sends the right half to the provider. That is why a route name never has to be a real model id.

The binary is not asked for — a Claude engine always uses the pinned CLI.

**Check:**

```bash
./hexaeight-agent-* export --plaintext --out /tmp/e.json && \
python3 -c "import json;e=json.load(open('/tmp/e.json'))['claude'];\
print('file   ',e['file']);print('approve',e['approve']);\
print('skills ',list(e.get('skills',{}).keys()));print('model  ',e['proxy']['model'])" && rm /tmp/e.json
```

Must show: `file` under `.heia/runtime`, `approve False`, `skills ['dir','priming']`, and a model
containing `|`. **If `skills` is missing the engine will have no skill tools at all** — and the only
symptom will be a later failure saying one specific tool is unavailable.

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

## 6b. Remote access — only if the human wants it

**Skip this entirely if the browser is on this machine.** `http://localhost:5620` is a secure
context and everything works with no tunnel, no certificate and nothing exposed.

Ask first: *"Do you need to reach this from another machine or a phone?"* If no, skip.

If yes, **both** the agent and the workspace need to be reachable over HTTPS, for different reasons:
the agent because the browser and the mobile app talk to it, the workspace because WebCrypto and
loopback-fetch rules make plain HTTP unusable.

**Install cloudflared** — it is a system binary, not an npm package:

```bash
# Linux
curl -sL -o /tmp/cloudflared \
  https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
chmod +x /tmp/cloudflared && sudo mv /tmp/cloudflared /usr/local/bin/cloudflared
cloudflared --version

# macOS
brew install cloudflared
```

**Point the agent at it.** Installing the binary is not enough — the agent must be told to use it,
and to publish the resulting URL:

```bash
cd ~/hbia-agent
python3 - <<'PY'
import json
p = 'hexaeight-agent.json'
d = json.load(open(p))
d['reach'] = {'mode': 'cloudflared'}   # agent starts its own tunnel and publishes that URL
d['register'] = True                    # and lists it in the registry, so it resolves by NAME
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

**Tell them this, because it will bite otherwise:** a quick tunnel gets a **new hostname every time
it restarts**. The agent re-registers itself, so resolving it by name keeps working — but any URL
someone bookmarked dies. For anything permanent, use a named Cloudflare tunnel (needs a Cloudflare
account) or a real DNS name plus a certificate, and set `reach` to
`{"mode": "custom", "url": "https://your-stable-host"}`.

---

## 7. Prove it end to end

Open the workspace, sign in with the agent name and the human's email, and send one message.

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
