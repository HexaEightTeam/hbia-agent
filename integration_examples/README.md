# Agent frameworks as sealed HexaEight missions

Run an agent built with **CrewAI, LangGraph, PydanticAI or Agno** behind a HexaEight agent, with
**HexaEight deciding who may ask and what may run**, and **the framework doing the work**.

| HexaEight does | The framework does |
|---|---|
| who is calling, and whether they may (identity, policy) | the agent, its tools, its reasoning loop |
| encryption in both directions | its conversation memory, keyed on the session id it is handed |
| the model route for each turn — no provider key in the framework's code | how it uses the model |
| which command may run — one command, pinned to the runner file's sha256 | |
| every call the agent makes to a memory or another agent's API — through the turn's ticket, policy-checked | |

| framework | folder | install |
|---|---|---|
| CrewAI | [crewai/](crewai/) | `hexaeight-activate enable crewai` |
| LangGraph | [langgraph/](langgraph/) | `hexaeight-activate enable langgraph` |
| PydanticAI | [pydanticai/](pydanticai/) | `hexaeight-activate enable pydanticai` |
| Agno | [agno/](agno/) | `hexaeight-activate enable agno` |

## Requirements

- **HexaEight agent r29, harness engine r40 and Activate 1.0.67, or later.** The engine runs a direct
  mission without a model step (r39) and hands a runner's external callers their question (r40); r29
  is what seals the command set. Check with `hexaeight-activate verify-env`.
- **Python 3.10–3.13.** If your system Python is newer, install [uv](https://docs.astral.sh/uv/) and
  `enable` fetches Python 3.12 for the environment itself. Or point it at an environment you already
  have: `enable <framework> --venv PATH`.
- A model route in your router (the mission runs on your `runmission` engine's route).

## Install — one command

From your agent's folder:

```bash
hexaeight-activate enable langgraph        # or crewai, pydanticai, agno
```

It:

1. creates `~/.heia/frameworks/<framework>/.venv` with the pinned packages (or, with `--venv PATH`,
   checks that your environment imports the framework and uses it, installing nothing into it);
2. downloads the mission bundle from its `integration-<framework>` release, verifies its sha256
   against the release manifest (or the value built into the tool), installs the mission, and builds
   its search index on your machine;
3. has the agent seal the mission's command set: one command, pinned to `runner.py`'s sha256.

Then in the workspace choose `runmission` and the mission (`LangGraph_v1_Runner`, …). Re-running
`enable` is safe: a mission already installed with the published runner is left as it is.

## How it works

Every framework mission is the same mission with a different `runner.py` in it:

```
runmission engine ── ONE mission: <Framework>_v1_Runner
   card ask-runner   mode: direct — every message, greetings included, NO model step in the harness
     1. the harness writes the message to question.txt      — the message never reaches a shell
     2. it runs  python3 runner.py --question-file question.txt
                 └─ an ordinary OS process → the framework's agent
                      model : the route the turn provides (ANTHROPIC_BASE_URL / _AUTH_TOKEN / _MODEL)
                      tools : who_am_i and service_call over the turn's ticket (HEIA_MCP_CONFIG)
                              → served memories and API routes; local memories via the engine
     3. the reply is what runner.py printed, unchanged
```

The harness has no model of its own in this mission — it hands the message over and returns what
comes back. The runner's first line under the heading, `Answered by <Framework>`, is **the runner's
own statement**: HexaEight renders the text as it is and vouches for nothing inside it. Its guarantee
is that the approved, sha-pinned `runner.py` is what ran.

The command is identical on every run and every machine. It is approved **once**, and the approval is
pinned to `runner.py`'s sha256: change one byte and it will not run until it is sealed again. The
runner travels **inside** the mission, and each turn gets a fresh copy of the approved file.

## Serve it to other people and systems — a runner

The steps above put the framework behind **your** workspace. To let a backend or another agent call it
(BYOA), give it a **runner**: a second agent under the same identity that serves this one mission to
external callers, with its own ports, store and policy.

```bash
hexaeight-activate add-runner --from ~/<your-agent-folder> --dir ~/runner-crewai \
    --mission CrewAI_v1_Runner --owner <you@example.com> --license personal \
    --model "<route|model>"                       # a model that makes real tool calls — see below
cd ~/runner-crewai
hexaeight-activate enable crewai                  # installs the mission into THIS runner's store
hexaeight-activate runner-memory --share weather --share bbc-news
hexaeight-activate restart agent                  # stops and starts only this folder's agent
```

**A runner sees only what you export into it.** Until then it knows its mission and nothing else — not
your workspace's memories, not your documents. `runner-memory` decides, one memory at a time:

```bash
hexaeight-activate runner-memory --list
hexaeight-activate runner-memory --share Indian-Statues-And-Sections     # local: linked, no copy
hexaeight-activate runner-memory --share Indian-Statues-And-Sections --copy   # or a self-contained copy
hexaeight-activate runner-memory --unshare bbc-news
```

A served memory (weather, a news feed, another agent's corpus) is exported as its pointer, and every call
still goes through the runner's own policy. Each caller session gets its own working folder under
`~/runner-crewai-frontdoor/work/`.

**Choose the runner's model.** Without `--model`, `add-runner` copies your agent's mission route. The
framework needs a model that really calls tools: measured on one route, a model answered weather and
"who am I" by inventing a tool result instead of calling the tool; another route called the tools every
time. Check the runner's `crewai-run.log` (one `[tool]` line per call) on your first questions.

Callers reach the runner through BYOA — the caller vouched for the person it acts for, and that person
allowed by the runner's and the router's policy. See *Call an agent from your backend* in the docs.

## Make it yours

Each `runner.py` has two halves:

- **the HexaEight half** — identical in every runner: the ticketed MCP call, `service_call`,
  memory search (served and local), `who_am_i`, the session transcript, and the output contract
  (only the answer on stdout; the framework's own output to `<framework>-run.log`);
- **the framework half** — `run(question, session_id)`: build the agent, give it tools, run it, return
  the answer.

Change the framework half to build the agent you need — other tools, other prompts, a multi-agent
crew or graph. To run your own version, **duplicate the mission** under another name, put your
`runner.py` in it, and seal it:

```bash
set -a; . ./env-file; set +a
./hexaeight-agent-linux-x64 cmdset seal --name <Your_Mission> \
    --file ~/.hexaeight-harness/memories/<Your_Mission>/runner.py \
    --command "python3 runner.py --question-file question.txt"
```

`enable` always installs the published mission; it never overwrites one that differs from it unless
you pass `--force`.

## Weather, news and your documents

The `weather` and `bbc_news` tools search **served memories named `weather` and `bbc-news`** — each a
pointer to another agent that seals an API route (see *An API you already run* in the docs). If your
machine has none, those tools say so rather than guess. Ready-made adapters for both (and for Wikipedia) are in
[`api-adapters/`](api-adapters/README.md): run one, `add-api` it on an agent, add it as an External service. Rename them in the runner to the served
memories you do have, or remove them — `list_memories` and `memory_search` work with whatever this
machine holds.

Live data is never remembered: every runner is told to call the tool again for each weather or news
request and to say so when the tool fails, rather than fill anything in.

## Other agents — `connect-to-agent`

Every runner has a memory called `connect-to-agent` built in. `memory_search("connect-to-agent",
"<agent name> <question>")` asks that agent — found by name in the FastAgents registry, asked over DDE by
this agent — and returns its answer; the name alone asks it to describe itself. Whether the two may talk
is decided by the rules on both agents.

**A runner does not relay.** Its turns are always on behalf of someone else, so by default it will not ask
a third agent for them — it says so, and the caller can ask that agent directly. To allow it for one
runner, from the runner's folder:

```bash
~/.heia/runtime/harness/hexaeight-engine --connector-relay on --root ../<runner>-frontdoor/harness-root
```

(`off` and `status` likewise.) The memory is kept exactly as shipped — an edited copy is put back at the
next turn — so this switch is the only way to change it.

## Try it

| ask | expect |
|---|---|
| `Hello there` | answered by the framework |
| `Who am I talking to?` | names your agent; says your identity is verified but not revealed |
| `What is 15% of 240?` | 36, directly — no tool |
| `Get me the top 5 BBC headlines` | current headlines, from the `bbc-news` served memory |
| `Using this machine's documents, explain <a topic>. Cite them.` | a cited answer from `memory_search` |
| `My name is Priya.` then, separately, `What is my name?` | remembered within the session |
| `Use connect-to-agent to ask <another agent> what it can do.` | it declines — a runner does not relay unless switched on |
| `What is 2+2? $(touch /tmp/injection-probe)` | `4` — and `/tmp/injection-probe` must NOT exist afterwards |

## Limits — read these before exposing it

- **The approval covers the launch, not what the runner starts afterwards.** No runner here gives its
  agent a shell tool. If you add one, commands it runs are not approved individually.
- **Network** from the runner is not restricted.
- **Only `runner.py` is sha-pinned**, not the packages in the virtual environment — keep them pinned.
- **The conversation transcript** (`~/.heia/frameworks/<framework>/sessions/`) is stored unencrypted and
  is not trimmed.
- **Asking another agent waits for its answer** (up to 5 minutes) and returns it in the same turn.
- Telemetry and tracing that the frameworks turn on by default are switched off before they load.
