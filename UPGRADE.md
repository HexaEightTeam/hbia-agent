# Upgrading an existing HBIA machine

This is for a machine that **already runs** an HBIA agent + workspace and is moving to the release
that bundles the **browser** and **memory** side services. It is not a fresh install — see INSTALL.md
for that. Read this whole file before running anything; two steps are ordering-sensitive and one is a
human decision.

## What is new in this release, and why the order matters

- The workspace bundle now carries **two side services**: the **browser service** (`:5623`, the
  remote-browser pane) and the **memory service** (`:5624`, the document-memory pane).
- The agent **supervises** them (like Node-RED) once `install-workspace` writes `services.browser` /
  `services.memory` into `hexaeight-agent.json`.
- The runtime gains one dependency, **puppeteer** (pinned 25.9.0). `install-runtime` installs it, and
  its first run downloads a headless Chromium (a few hundred MB).
- The default engines now include **chat** (assistant + `$ui` + browser), **mission** (AI-driven
  mission authoring) and **prepare** (plan mode), each sealed with its real prompt. `engine validate`
  upgrades an existing install's engines to these in place.

## 0. STOP the services you already start yourself — FIRST

**If this machine starts the services from a user cron / login script / launchd, stop that path
before upgrading.** The upgrade re-registers the browser and memory services under the *agent's*
supervisor, and a second copy started by your own cron will fight the agent for `:5623` / `:5624` —
the port is taken, the agent adopts the wrong instance, and nothing reports why.

```bash
# 1. Take the user cron / login services down NOW (adapt to how yours are launched):
#    - crontab -l   → comment out the lines that start browser-service / memory-service / the agent
#    - or:  pkill -f browser-service/service.mjs ; pkill -f memory-service/service.mjs
# 2. Stop the running stack cleanly:
hexaeight-activate stop all          # workspace, agent, router — in the safe order
```

Leave the cron **edited but not yet re-enabled** — you will point it at the new layout in §4.

## 1. Update the tool

```bash
dotnet tool update -g HexaEight.Activate --no-cache
hexaeight-activate --version          # expect 1.0.42 or newer
```

## 2. Update the runtime and the agent

```bash
cd ~/hbia-agent                        # the identity folder

hexaeight-activate install-runtime     # installs puppeteer (25.9.0) → first run pulls Chromium
hexaeight-activate install-agent       # downloads + hash-verifies the new agent + engines
```

`install-runtime` is what makes the **browser** service able to launch Chromium. Skip it and the
browser pane starts, adopts nothing, and the agent logs `browser: NOT STARTABLE`.

## 3. Update the workspace — this bundles and registers the services

```bash
cd ~/hbia-workspace                     # identity folder (env-file + hexaeight.mac), NOT the UI dir
hexaeight-activate install-workspace --force --agent <agent identity name>
```

This fetches the new bundle (UI + `browser-service/` + `memory-service/`), lays the services down
under `~/.heia/runtime/workspace/`, and writes `services.browser` / `services.memory` into the agent
config. It prints exactly what it registered.

> If `install-workspace` says it could **not** register the services ("no hexaeight-agent.json in
> this folder"), run it from the agent identity folder instead, or copy the two `services.*` blocks
> it printed into `~/hbia-agent/hexaeight-agent.json` by hand.

**Upgrade the engines' prompts in place** (chat → `$ui` + browser, mission → the authoring engine):

```bash
cd ~/hbia-agent
hexaeight-activate engine --validate    # re-seals known engines to the current prompt set
```

## 4. Put the NEW services in your local startup — replacing the old lines

If §0 disabled a user cron / launchd that started the services, it started the **old** paths. Do not
re-enable those. There are two supported ways to have them start at boot from here on:

- **Preferred — let the agent supervise them.** They are now in the agent config, so **whatever
  starts the agent at boot also brings up browser + memory.** If your cron already starts the agent,
  that single line is now enough — delete the separate browser/memory lines. Or use the tool's own
  autostart, which starts router → agent (→ services) in the right order:

  ```bash
  hexaeight-activate autostart on
  ```

- **If you insist on starting the services from cron yourself,** point the lines at the NEW installed
  location and pass the same env the agent uses:

  ```bash
  # browser  (:5623)
  BROWSER_PUBKEY_FILE=$HOME/.heia/browser/pubkey \
    node $HOME/.heia/runtime/workspace/browser-service/service.mjs &
  # memory   (:5624)
  MEM_ROOT=$HOME/.hexaeight-harness MEM_ENGINE=$HOME/.heia/runtime/harness/hexaeight-engine \
  MEM_PORT=5624  node $HOME/.heia/runtime/workspace/memory-service/service.mjs &
  ```

  The old cron pointed at wherever the services used to live (often a source checkout). Those paths
  are gone — leaving them is the most common post-upgrade failure.

## 5. Start everything, in order, and verify

```bash
cd ~/hbia-agent
hexaeight-activate restart router        # restarts the router, THEN the agent, THEN its services
hexaeight-activate checkservices         # agent / node-red / browser / memory all UP
```

`restart router` cascades on purpose: the agent holds routes into the router, and the browser/memory
services are the agent's, so bouncing the router alone would leave the agent calling a listener that
no longer exists. `checkservices` starts anything the supervisor adopted-then-lost.

Then, in the browser: open a chat, ask a question, open the **Browser** pane (it should show a page
and survive switching sessions/tabs), and open the **Memory** pane. All three working is the proof
the upgrade landed.

## Rollback

Binaries and the bundle are versioned; the identity and config are not touched destructively. To go
back: `dotnet tool update -g HexaEight.Activate --version <old>`, re-run `install-agent` /
`install-workspace` against the previous release tag, and restart. The `services.*` blocks are
additive — an older agent simply ignores service names it does not supervise.
