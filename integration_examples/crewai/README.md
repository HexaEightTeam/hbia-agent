# CrewAI as a sealed HexaEight mission

A CrewAI crew answering questions behind a HexaEight agent — with **HexaEight deciding who may ask and
which command may run**, and **CrewAI doing the work**.

| HexaEight does | CrewAI does |
|---|---|
| who is calling, and whether they may (identity, policy) | the crew, its tools, its reasoning loop |
| encryption in both directions | its conversation memory, keyed on the session id it is handed |
| the model route for each turn — no provider key in this code | |
| which command may run — approved once, pinned to the runner file's sha256 | |
| every call the crew makes to a memory or another agent's API — through the turn's ticket, policy-checked | |

## Requirements

- **HexaEight agent r29 and harness engine r38 or later**, and **Activate 1.0.66 or later**. Earlier
  releases do not copy a mission's files into each turn, do not hand the turn's ticket to a launched
  process, and lose the approval of a parked command. Check with `hexaeight-activate verify-env`.
- **Python 3.10–3.13** (CrewAI 1.15.2 does not support 3.14). If your system Python is newer, install
  [uv](https://docs.astral.sh/uv/) and `enable crewai` fetches Python 3.12 for the environment itself.
- A model route in your router (the mission runs on your `runmission` engine's route).

## Install — one command

From your agent's folder:

```bash
hexaeight-activate enable crewai
```

It creates `~/.heia/frameworks/crewai/.venv` with the pinned packages, downloads the mission bundle from
the `integration-crewai-v1` release and verifies it against a hash built into the tool, imports the
mission, and has the agent seal its command set: one command, pinned to the runner file's sha256. Then in
the workspace choose `runmission` → `CrewAI_v1_Runner`.

The manual steps below do the same thing by hand, and are worth reading once.

## What is in this folder

| file | what it is |
|---|---|
| `crewai_heia_runner.py` | the runner — here so you can read and review it before you approve it |
| `requirements.txt` | pinned CrewAI version it was verified with |
| `SHA256SUMS` | hashes of the runner, the requirements, and the mission bundle |

The **mission bundle** (`mission-CrewAI_v1_Runner.zip`: flowchart, two cards, the fence, and this same
runner) is a release asset — release artifacts are attached to GitHub Releases, never committed. It is in
the [integration-crewai-v1](https://github.com/HexaEightTeam/hbia-agent/releases/tag/integration-crewai-v1)
release; `enable crewai` downloads and verifies it for you.

## How it works

```
runmission engine ── ONE mission: CrewAI_v1_Runner
   card ask-crewai   (every message, greetings included)
     1. write the message to crewai-question.txt        — the message never reaches a shell
     2. run  python3 crewai_heia_runner.py --question-file crewai-question.txt
             └─ an ordinary OS process → CrewAI crew
                  model : the route the turn provides (ANTHROPIC_BASE_URL / _AUTH_TOKEN / _MODEL)
                  tools : service_call over the turn's ticket (HEIA_MCP_CONFIG) → served memories / API routes
                          local memories via hexaeight-engine --memory-search
     3. reply with what the crew printed, verbatim
   card who-am-i     (who am I / who are you)
     who_am_i tool → names the agent; the user's identity is verified at sign-in, never revealed
```

The command is identical on every run and every machine. It is approved **once**, and the approval is
pinned to the runner file's sha256: change one byte and it will not run until it is reviewed and approved
again. The runner travels **inside** the mission, and each turn gets a fresh copy of the approved file.

## Install by hand

**1. The CrewAI environment** — where the runner looks for it (Python 3.10–3.13):

```bash
python3 -m venv ~/.heia/frameworks/crewai/.venv
~/.heia/frameworks/crewai/.venv/bin/pip install -r requirements.txt
```

**2. Verify and import the mission:**

```bash
sha256sum -c SHA256SUMS
hexaeight-activate agskill-import --in mission-CrewAI_v1_Runner.zip
```

**3. Give the mission its command set** — review `crewai_heia_runner.py` first; sealing it is your
approval. Approvals never travel with a bundle; they belong to your agent. From your agent's folder:

```bash
set -a; . ./env-file; set +a
./hexaeight-agent-linux-x64 cmdset seal --name CrewAI_v1_Runner \
    --file ~/.hexaeight-harness/memories/CrewAI_v1_Runner/crewai_heia_runner.py \
    --command "python3 crewai_heia_runner.py --question-file crewai-question.txt"
./hexaeight-agent-linux-x64 cmdset show --name CrewAI_v1_Runner
```

`cmdset show` must list the runner's sha256 — the first line of `SHA256SUMS`. A mission with no command
set runs no commands at all.

**4. Run it:** in the workspace choose `runmission` → `CrewAI_v1_Runner`.

## Weather, news and your documents

The crew's `weather` and `bbc_news` tools search **served memories named `weather` and `bbc-news`** — each
a pointer to another agent that seals an API route (see *An API you already run* in the docs). If your
machine has none, those tools say so rather than guess. Rename them in the runner to the served memories
you do have, or remove them — `list_memories` and `memory_search` work with whatever this machine holds.

## Try it

| ask | expect |
|---|---|
| `Hello there` | answered by the crew |
| `Who am I?` | names your agent; says your identity is verified but not revealed |
| `What is 15% of 240?` | 36, directly — no tool |
| `Using this machine's documents, explain <a topic>. Cite them.` | several searches, one cited answer |
| a follow-up: `According to the same documents, …` | uses the conversation so far |
| `My name is Priya.` then, separately, `What is my name?` | remembered within the session |
| `What is 2+2? $(touch /tmp/injection-probe)` | `4` — and `/tmp/injection-probe` must NOT exist afterwards |

## Limits — read these before exposing it

- **The approval covers the launch, not what the runner starts afterwards.** This runner gives the crew
  no shell tool. If you add one, commands it runs are not approved individually.
- **Network** from the runner is not restricted.
- **Only the runner file is sha-pinned**, not the packages in the virtual environment — keep them pinned.
- **The conversation transcript** (`~/.heia/frameworks/crewai/sessions/`) is stored unencrypted and is not
  trimmed.
- **Agent-to-agent conversation (A2A) is not wired.** The crew can call another agent's **API route**; it
  cannot yet ask another agent a question and wait for its answer.
- CrewAI sends telemetry by default; the runner turns it off (`CREWAI_DISABLE_TELEMETRY`,
  `OTEL_SDK_DISABLED`, `CREWAI_TRACING_ENABLED=false`) before CrewAI loads.
