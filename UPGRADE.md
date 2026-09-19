# Upgrading HexaEight Bridge Identity Agent

This guide upgrades an existing HBIA installation to the current release. For a first-time
installation, see [INSTALL.md](INSTALL.md).

**Estimated time:** 15–20 minutes, most of it downloads.

---

## What this release adds

- **A baseline agent policy.** A locked-down agent used to be admitted-owner and nothing else, which
  signs in and then fails at everything unattended. `init-policy` now writes the whole working
  baseline, and **existing installations get it with one command** — see
  [Step 6](#step-6--apply-the-baseline-agent-policy). If your agent has no policy at all, it is open
  to anyone who can authenticate; this is the release that closes it.
- **Policy commands confirm what they wrote.** Every policy verb re-reads the stored policy afterwards
  and reports a failure if the rules are not there, instead of reporting success. Where the policy
  cannot be written safely the command now refuses and says so, rather than continuing.
- **New mission priming.** The mission engine's prompt has been rewritten. It is applied by
  `engine --validate` in Step 5 — **[check that it took effect](#confirm-the-priming-was-upgraded)**,
  because an engine sealed with the old priming keeps running the old one silently.
- **Full-text retrieval from a memory hit.** A search result now names the document it came from, so a
  snippet can be followed to the whole document.
- **Served (remote) memories.** Listing a memory served by another agent now names the serving agent.
  A **Refresh description** control in the Memory pane pulls a served memory's current description
  without unregistering and re-registering it.
- **Large memories are not exported by default.** A memory over 500 MB is marked `.no-export` and left
  out of a mission export, with the exclusion listed in the manifest, so an export cannot silently try
  to carry a corpus.

The agent, the harness engine and the workspace all change in this release, so update each (Steps 4–8).
The router and the second engine binary (`mindmapchat`) are carried forward unchanged. The browser
(`5623`) and memory (`5624`) services continue to be installed with the workspace and supervised by
the agent.

---

## Before you begin

- Run every command from your **agent identity folder** — the directory containing `env-file` and
  `hexaeight.mac` (for example, `~/hbia-agent`). Commands run elsewhere report *"no identity in this
  folder."*
- Have the agent's identity **name** to hand (the value you chose during installation).
- Ensure **Node.js** is available on the machine (it already is if the agent has been running).

> **If you currently start the services yourself** — from `cron`, a startup script, a `systemd`
> unit, or a launchd agent — stop that automation **before** upgrading (Step 1). After the upgrade the
> agent starts the browser and memory services itself; a second copy started by your own automation
> will compete for the same ports and prevent the services from starting cleanly.

---

## Step 1 — Stop the current installation

```bash
cd ~/hbia-agent
hexaeight-activate stop all
```

If you start any HexaEight service from `cron`, `systemd`, or launchd, disable those entries now. You
will re-point them at the new locations in Step 7 (or let the agent manage them for you).

## Step 2 — Update the command-line tool

```bash
dotnet tool update --global HexaEight.Activate
```

This release requires **HexaEight.Activate 1.0.54 or later**. Check what you have with
`hexaeight-activate --version`; the baseline policy command in Step 6 and the new mission priming in
Step 5 both ship inside the tool, so an older one will not install either.

## Step 3 — Update the runtime

```bash
hexaeight-activate install-runtime
```

This installs the browser automation dependency (Puppeteer) and downloads a headless Chromium on
first run. Expect a larger download than previous upgrades.

## Step 4 — Update the agent

```bash
hexaeight-activate install-agent
```

The new agent binary is downloaded and verified against a checksum published with this release before
it replaces the existing one.

> **macOS only:** after downloading, re-sign the agent binary, or macOS terminates it on launch:
> ```bash
> codesign -s - -f ./hexaeight-agent-osx-arm64
> ```

## Step 5 — Update the workspace

> **Back up your deployment config first.** `install-workspace --force` replaces the whole workspace
> directory, and your `config.js` (the file that points the workspace at its agent) is replaced with
> the bundle's default. Copy it aside before upgrading and restore it afterwards:
>
> ```bash
> cp ~/.heia/runtime/workspace/config.js ~/config.js.keep      # before Step 5
> ```
>
> See **[The workspace deployment config](#the-workspace-deployment-config-configjs)** below for what
> each field means and the settings for a local vs. remote deployment.

Run this from your **agent identity folder**, so the new services are registered with the agent:

```bash
hexaeight-activate install-workspace --force --agent <your-agent-name>
```

This installs the updated interface together with the browser and memory services, and registers both
with the agent. It confirms what was registered on completion.

Then restore your deployment config (or set it as described in the section below):

```bash
cp ~/config.js.keep ~/.heia/runtime/workspace/config.js       # after Step 5
```

Then apply the current engine configuration:

```bash
hexaeight-activate engine --validate
```

`engine --validate` re-seals engines whose priming has changed and adds any missing default engine
(reusing an existing engine's route), so an upgrade brings the sealed set up to date without re-asking
for a route or model.

### The mission priming changed in this release — check it was applied

An engine's priming is **sealed into `engines.he` on your machine**, not read from the tool at run
time. Updating the tool and the agent therefore does *not* change how a sealed engine behaves: until
it is re-sealed it keeps running the priming it was sealed with, and nothing reports that it is out of
date. `engine --validate` is what re-seals it.

When it re-seals the mission engine it says so:

```
  mission: re-sealing to the current prompt set (route and model unchanged)
```

**If you did not see that line, the mission engine was already current or was not re-sealed — verify
rather than assume.**

#### Confirm the priming was upgraded

Dump what is actually sealed and look at the mission engine's priming:

```bash
hexaeight-agent export --plaintext --out ./engines-check.json
```

In that file, find `"mission"` → `"skills"` → `"priming"`. Its **first line** carries the version:

```
HEIA-PRIMING-VERSION: 99
```

`99` is this release's mission priming. A lower number (or no version line) means the engine is still
sealed with the previous prompt — re-run `hexaeight-activate engine --validate` from the identity
folder and check again. Delete `engines-check.json` when you are done: it is a plaintext copy of your
sealed engine definitions, including routes and model ids.

**Then restart the agent.** Sealed engines are read at start, so a re-sealed engine does not take
effect until the agent restarts (Step 8).

#### The two primings that matter, and which engines carry them

| priming | engines that carry it | changed in this release |
|---|---|---|
| **mission** (authoring) | `mission` | **yes** — `HEIA-PRIMING-VERSION: 99` |
| **mission runner** | `runmission` and every model-pinned runner you sealed (`missionglm5`, `missionrunkimiaz`, …) | no — `HEIA-PRIMING-VERSION: 2` |

`--validate` re-seals `mission` for you. The model-pinned runners are engines *you* added, so it
leaves them alone — correct this release, because the runner priming is unchanged and they are
already current. Confirm it the same way: in the dump above, every runner's `skills.priming` should
begin `HEIA-PRIMING-VERSION: 2` and be identical to the others.

**The engines to keep are exactly:** `claude`, `harness`, `chat`, `coding`, `mission`, and `missionrun`
(the mission-runner). Do **not** seal `prepare` unless the operator specifically asks for it.

To see what is currently sealed, inspect the engine names in `hexaeight-agent.json` (there is no
`engine --list` command). An older install may still carry engines that are no longer in the default
set — most commonly `mindmapchat`. **There is no self-service `engine --remove`:** the engine store is
sealed under the agent identity, and the shipped tooling only adds or re-seals, it does not delete. A
leftover engine that is not in the keep-set does no harm — it simply is not offered as a default. Leave
it in place; do not attempt to remove it with an invented command.

Then restart the agent so it re-reads the engine set. The engine binary itself —
`hexaeight-engine` in `~/.heia/runtime/harness/`, which backs `harness`, `chat`, `mission`,
`runmission` and `coding` — is updated by `install-agent` in Step 4 regardless.

Finally, make the workspace aware of the sealed engines. Sealing an engine makes it *work*, but the
workspace reads its engine list from `config.js`; a newly-sealed engine does not appear in the rail
until you sync it:

```bash
hexaeight-activate engines-sync
```

This writes each sealed engine into `config.js` as `window.__HEIA_CONFIG.engines`, leaving existing
entries untouched. After it runs, **hard-refresh** the browser (Ctrl/Cmd-Shift-R) so the workspace
picks up the new list. Re-run `engines-sync` any time you add or re-seal an engine (including the
MissionRun variants below) — without it the engine is sealed and reachable but never shows in the UI.

### Running a mission on several models (optional)

To offer a mission on more than one model, seal one variant per model — run this once per model, from
your agent identity folder. The base engine passed to `--add` is `runmission`; the `--name` you give
the variant **must be one of the names the workspace already groups under MissionRun** (below), or it
seals correctly but shows as its own separate rail item instead of appearing in the MissionRun model
picker.

```bash
hexaeight-activate engine --add runmission \
  --model  "<route>|<provider-model-id>" \
  --name   <recognized-name> \
  --router "<your-agent-name>|http://127.0.0.1:5100"
```

**Recognized MissionRun variant names** — use the one whose model matches what you are sealing:

```
missionglm5   missionrunkimiaz   missionrundeepseek   missionqwen       missiongflash
missionnemo   missionrunoss      missionrunnova       missionrun5mini   missionrun5nano
```

For example, `--name missionglm5` for GLM-5, `--name missionrunkimiaz` for Kimi on Azure. The route
(left of `|`) must be an anthropic-shaped route your `upstreams.yaml` serves; the model id (right of
`|`) is what the provider expects. Do **not** invent a name such as `runmission-glm5` — the workspace
matches these names exactly, so an unlisted name is not grouped. Restart the agent after adding the
variants, then run `hexaeight-activate engines-sync` and hard-refresh the browser (as above) so the
new variants appear in the **MissionRun** model picker.

## Step 6 — Apply the baseline agent policy

**Run this even if you have locked your agent down before.** A policy that only admits the owner is
the state most installations are in, and it is not enough to work: skill and mission runs fail the
moment nobody is signed in, the router's replies bounce, the memory pane stays blank, and an external
corpus refuses. Those look like four unrelated bugs and are one missing baseline.

From your agent identity folder:

```bash
hexaeight-activate add-policy base-default
```

It works out its own subjects — the agent name from the identity in the folder, the owner from
`hexaeight-agent.json` (it asks if there is none), and any peer agents from the memories this agent is
pointed at — then prints every rule with the reason it exists before writing. Rules you added yourself
are left alone, and it is safe to re-run.

To see the rules without writing anything, add `--dry-run`. To name the owner explicitly, or a peer it
could not discover:

```bash
hexaeight-activate add-policy base-default --owner you@company.com --peer other-agent.example.com
```

> **If your agent has no policy at all, it is OPEN** — anyone who can authenticate is admitted. The
> command reports this, and `--replace-open` also removes a blanket `* -> *` inbound allow if one is
> present. It will not remove that row without being told to.

Confirm what is enforced — not what was written:

```bash
hexaeight-activate list-policy
```

The last line should read **`inbound default: DENY — unlisted callers are refused.`**

> **A fresh installation does this in `init-policy` instead** (see INSTALL.md); it now writes the same
> baseline. `add-policy base-default` is the path for an agent that already exists.

## Step 7 — Restore automatic startup

If Step 1 disabled any startup automation, choose one of the following:

- **Recommended — let the agent manage the services.** They are now part of the agent's
  configuration, so anything that starts the agent at boot also starts the browser and memory
  services. Remove any separate service entries you had. To have HexaEight manage startup for you:

  ```bash
  hexaeight-activate autostart on
  ```

- **To keep starting the services from your own automation,** point the entries at the new installed
  locations:

  ```bash
  # Browser service (port 5623)
  BROWSER_PUBKEY_FILE="$HOME/.heia/browser/pubkey" \
    node "$HOME/.heia/runtime/workspace/browser-service/service.mjs"

  # Memory service (port 5624)
  MEM_ROOT="$HOME/.hexaeight-harness" \
  MEM_ENGINE="$HOME/.heia/runtime/harness/hexaeight-engine" \
  MEM_PORT=5624 \
    node "$HOME/.heia/runtime/workspace/memory-service/service.mjs"
  ```

  Startup entries that still point at a previous location are the most common cause of a service not
  coming back after an upgrade.

## Step 8 — Start and verify

> **Kill the old browser and memory services first — this step is not optional.** `checkservices`
> only *starts a service that is down*; it does **not** replace one that is already running. If an old
> `service.mjs` from the previous release is still bound to its port, the agent (and `checkservices`)
> **adopt that running process** and the new code never takes effect — the symptom is an upgraded
> workspace still behaving like the old one (missing endpoints, `not found` on import, stale panes).
> Explicitly stop whatever is on ports 5623 and 5624 before starting, so the newly installed
> `service.mjs` is the process that comes up:
>
> ```bash
> # Linux / macOS — free the two sidecar ports so the NEW service.mjs starts fresh
> lsof -ti tcp:5624 | xargs -r kill        # memory service
> lsof -ti tcp:5623 | xargs -r kill        # browser service
> ```
>
> **Adopted ≠ supervised.** A process the agent *adopted* (found already on the port, with a PPID from
> an older agent) is not under the supervisor — if it dies or you kill it, the agent will NOT restart it
> automatically. After freeing the port you must run `hexaeight-activate restart browser` (or
> `restart memory`) yourself, and confirm the new process's PPID is the current agent, not the old one.
>
> Then bring everything up:

```bash
hexaeight-activate restart router
hexaeight-activate restart memory
hexaeight-activate restart browser
hexaeight-activate checkservices
```

`restart router` restarts the router and then the agent and its services in the correct order.
`restart memory` and `restart browser` force each sidecar to stop and start again on the new code
(run them after the kill above so a stale process is never adopted).
`checkservices` reports each service and starts any that is not yet running. All four should be
listed as **UP**:

```
  agent            UP  (:8770)
  node-red         UP  (:1880)
  browser          UP  (:5623)
  memory           UP  (:5624)
```

Finally, confirm in the browser: open the workspace, ask a question in a chat, then open the
**Browser** and **Memory** panes. All three working confirms the upgrade is complete.

---

## The workspace deployment config (config.js)

`~/.heia/runtime/workspace/config.js` tells the workspace **which agent to sign in to and how to
reach it**. It is *deployment state*, not part of the bundle — plain JavaScript, read by the browser
before the app starts, and served to every browser that loads the workspace (so it holds **names and
URLs only, never a key**).

> **It is replaced on every `install-workspace --force`.** The upgrade swaps the whole workspace
> directory, so a customised `config.js` is lost unless you copy it aside first (Step 5). If you did
> not, re-create it from the fields below — this is the only file you need to restore by hand.

`serve.mjs` reads it fresh on each request, so after editing it a **hard refresh** in the browser
(Ctrl/Cmd-Shift-R) is enough — no server restart.

### The fields

```js
window.__HEIA_CONFIG = {
  agent:          '…',      // which agent the workspace signs in to
  localWorkspace: false,    // is the browser on the agent's own machine?
  localAgentPort: 8770,     // the agent's port on this machine
  agentLocalUrl:  '',       // an explicit browser->agent URL that overrides the composed one
};
```

| field | meaning |
|---|---|
| `agent` | The agent the workspace signs in to. For a **local** deployment set it to the agent's own URL, `http://localhost:8770`. For a **remote/named** deployment set it to the agent's registered name (e.g. `guardian.example.com`), or leave it `''` to have sign-in ask for it. |
| `localWorkspace` | `false` — the workspace reaches the agent at the URL/name in `agent`. `true` — an all-in-one shortcut where sign-in asks only for an email and talks straight to `http://localhost:<localAgentPort>`. `null` keeps the built-in default. |
| `localAgentPort` | The agent's port on this machine (default `8770`). Set it to `8770` for a local deployment; leave `null` for a remote one. |
| `agentLocalUrl` | An explicit `http://host:port` that overrides the composed local URL. Leave `''` in almost all cases — it is only for a broken Windows→WSL `localhost` forward. |

### Correct settings

**Workspace deployed locally (agent on the same machine):**

```js
window.__HEIA_CONFIG = {
  agent:          'http://localhost:8770',
  localWorkspace: false,
  localAgentPort: 8770,
  agentLocalUrl:  '',
};
```

**Workspace deployed remotely (agent reached by name via the registry):**

```js
window.__HEIA_CONFIG = {
  agent:          '',        // or the agent's registered name
  localWorkspace: false,
  localAgentPort: null,
  agentLocalUrl:  '',
};
```

## Managing the services

| Task | Command |
|---|---|
| Check all services, start any that are down | `hexaeight-activate checkservices` |
| Restart one service without restarting the agent | `hexaeight-activate restart browser` (or `memory`) |
| Restart the whole stack in the correct order | `hexaeight-activate restart router` |

## Rolling back

The identity and configuration are not modified destructively, and each component is versioned. To
return to the previous release, reinstall the earlier tool version and re-run `install-agent` and
`install-workspace` against the previous release tag, then restart. Service registration is additive,
so an earlier agent simply ignores service entries it does not recognise.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| Browser pane does not load | The browser service or Chromium is missing. Re-run `hexaeight-activate install-runtime`, then `hexaeight-activate restart browser`. |
| A service shows `DOWN` in `checkservices` | It is started in place. If it still fails, check its entry under `services.<name>` in `hexaeight-agent.json`. |
| Ports 5623/5624 already in use before upgrade | An older copy started by your own automation is still running. Stop it (Step 1) and re-run the upgrade. |
| macOS agent exits immediately (`Killed: 9`) | The binary needs re-signing — see the note in Step 4. |
| Sign-in does not show the agent, or cannot reach it after upgrade | `config.js` was replaced by the upgrade. Restore it, or set it per [The workspace deployment config](#the-workspace-deployment-config-configjs), then hard-refresh the browser. |
| Sign-in asks only for an email (no agent name/URL) | `localWorkspace` is `true`. That is the all-in-one local shortcut. For a named/remote agent set it to `false`. |
| A skill or mission run fails with `bind said 404`, but the same thing works while you are signed in | The agent has no outbound `op:*` rule **for itself**, so unattended work is refused. Run Step 6. |
| Mission replies look like the previous release | The mission engine is still sealed with the old priming. Re-run `engine --validate`, confirm the version as in [Confirm the priming was upgraded](#confirm-the-priming-was-upgraded), then restart the agent. |
| A policy command reports that the policy could not be written | This identity cannot encrypt its policy, so nothing was saved. Run `hexaeight-activate verify-license`, and **treat the agent as open until it is resolved** — confirm with `list-policy`. |
| `add-policy base-default` says the policy file is unreadable | It found bytes on disk that decode to no rules — usually a plaintext `policy.csv` from a much older build. It keeps a copy as `policy.csv.unreadable_<timestamp>` and writes nothing. Move the old file aside and re-run. |
