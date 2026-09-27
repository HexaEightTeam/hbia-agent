# Agno as a sealed HexaEight mission

A Agno agent answering behind a HexaEight agent. How it works, requirements, limits and how to change it
are the same for every framework — read **[the shared README](../README.md)** first.

## Install

From your agent's folder:

```bash
hexaeight-activate enable agno                 # a pinned environment of its own
hexaeight-activate enable agno --venv PATH     # or an environment you already have
```

Then in the workspace choose `runmission` → `Agno_v1_Runner`.

## What is in this folder

| file | what it is |
|---|---|
| `runner.py` | the runner — here so you can read and review it before you approve it |
| `requirements.txt` | the pinned packages it was verified with |
| `SHA256SUMS` | hashes of the runner, the requirements, and the mission bundle |

The **mission bundle** (`mission-Agno_v1_Runner.zip`) is a release asset:
[integration-agno-v1](https://github.com/HexaEightTeam/hbia-agent/releases/tag/integration-agno-v1). `enable agno` downloads and verifies it.

## The Agno half of the runner

An Agno `Agent` with the five tools as plain functions; the reply is its final assistant message only, not the text it wrote before a tool call. The model is Agno's `Claude` on the turn's route, authenticated with the turn's token.

Its conversation transcript is kept in `~/.heia/frameworks/agno/sessions/`, and its own output goes to
`agno-run.log` in the session's working folder.

## Install by hand

```bash
python3 -m venv ~/.heia/frameworks/agno/.venv                       # Python 3.10–3.13
~/.heia/frameworks/agno/.venv/bin/pip install -r requirements.txt
sha256sum -c SHA256SUMS
hexaeight-activate agskill-import --in mission-Agno_v1_Runner.zip
set -a; . ./env-file; set +a                                           # in your agent's folder
./hexaeight-agent-linux-x64 cmdset seal --name Agno_v1_Runner     --file ~/.hexaeight-harness/memories/Agno_v1_Runner/runner.py     --command "python3 runner.py --question-file question.txt"
```

Sealing is your approval: review `runner.py` first. `cmdset show --name Agno_v1_Runner` must list the runner's
sha256 — the first line of `SHA256SUMS`.
