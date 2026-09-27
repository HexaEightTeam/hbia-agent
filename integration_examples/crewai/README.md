# CrewAI as a sealed HexaEight mission

A CrewAI agent answering behind a HexaEight agent. How it works, requirements, limits and how to change it
are the same for every framework — read **[the shared README](../README.md)** first.

## Install

From your agent's folder:

```bash
hexaeight-activate enable crewai                 # a pinned environment of its own
hexaeight-activate enable crewai --venv PATH     # or an environment you already have
```

Then in the workspace choose `runmission` → `CrewAI_v1_Runner`.

## What is in this folder

| file | what it is |
|---|---|
| `runner.py` | the runner — here so you can read and review it before you approve it |
| `requirements.txt` | the pinned packages it was verified with |
| `SHA256SUMS` | hashes of the runner, the requirements, and the mission bundle |

The **mission bundle** (`mission-CrewAI_v1_Runner.zip`) is a release asset:
[integration-crewai-v2](https://github.com/HexaEightTeam/hbia-agent/releases/tag/integration-crewai-v2). `enable crewai` downloads and verifies it.

## The CrewAI half of the runner

One CrewAI `Agent` with the five tools, one `Task` carrying the conversation so far, run as a sequential `Crew`. The model is CrewAI's `LLM` (LiteLLM underneath) on the turn's route, with the turn's token as a bearer header.

Its conversation transcript is kept in `~/.heia/frameworks/crewai/sessions/`, and its own output goes to
`crewai-run.log` in the session's working folder.

## Install by hand

```bash
python3 -m venv ~/.heia/frameworks/crewai/.venv                       # Python 3.10–3.13
~/.heia/frameworks/crewai/.venv/bin/pip install -r requirements.txt
sha256sum -c SHA256SUMS
hexaeight-activate agskill-import --in mission-CrewAI_v1_Runner.zip
set -a; . ./env-file; set +a                                           # in your agent's folder
./hexaeight-agent-linux-x64 cmdset seal --name CrewAI_v1_Runner     --file ~/.hexaeight-harness/memories/CrewAI_v1_Runner/runner.py     --command "python3 runner.py --question-file question.txt"
```

Sealing is your approval: review `runner.py` first. `cmdset show --name CrewAI_v1_Runner` must list the runner's
sha256 — the first line of `SHA256SUMS`.
