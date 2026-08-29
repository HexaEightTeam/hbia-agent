# Upgrading HexaEight Bridge Identity Agent

This guide upgrades an existing HBIA installation to the release that adds the workspace **browser**
and **memory** services. For a first-time installation, see [INSTALL.md](INSTALL.md).

**Estimated time:** 15–20 minutes, most of it downloads.

---

## What this release adds

- **Browser pane** — a live, agent-driven browser in the workspace, served by a new *browser
  service* on port `5623`.
- **Memory pane** — browse, add and search document memories, served by a new *memory service* on
  port `5624`.

Both services are installed with the workspace and are supervised by the agent, alongside Node-RED.
The browser service uses Chromium, which the runtime installer now provides.

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
will re-point them at the new locations in Step 6 (or let the agent manage them for you).

## Step 2 — Update the command-line tool

```bash
dotnet tool update --global HexaEight.Activate
```

This release requires **HexaEight.Activate 1.0.43 or later**.

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

Run this from your **agent identity folder**, so the new services are registered with the agent:

```bash
hexaeight-activate install-workspace --force --agent <your-agent-name>
```

This installs the updated interface together with the browser and memory services, and registers both
with the agent. It confirms what was registered on completion.

Then apply the current engine configuration:

```bash
hexaeight-activate engine --validate
```

## Step 6 — Restore automatic startup

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

## Step 7 — Start and verify

```bash
hexaeight-activate restart router
hexaeight-activate checkservices
```

`restart router` restarts the router and then the agent and its services in the correct order.
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
