"""CrewAI runner, launched by a HexaEight mission as an ordinary OS process.

ONE SELF-CONTAINED FILE ON PURPOSE: the mission's approval pins this file's sha256, and only the file
named in the command is pinned — so nothing it depends on lives in another file of ours.

    python3 runner.py --question-file question.txt

Run from the session's working folder; no machine path appears in the command. If the python3 that
launched it has no CrewAI, it re-launches itself with the CrewAI environment that
`hexaeight-activate enable crewai` installs (HEIA_CREWAI_PYTHON overrides where that is).

HexaEight (via the harness that launches this) supplies, in the environment:
  ANTHROPIC_BASE_URL / ANTHROPIC_AUTH_TOKEN / ANTHROPIC_MODEL   the model route for this turn
  HEIA_WORK_SESSION                                             the session id (the crew keys its transcript on it)
  HEIA_MCP_CONFIG                                               this turn's ticketed MCP config (weather, BBC, memories)
CrewAI owns everything else: the crew, its tools, its loop, its session transcript.
Prints the answer on stdout and nothing else.
"""
FRAMEWORK = "CrewAI"
FW_KEY = "crewai"               # venv folder, env override HEIA_CREWAI_PYTHON
FW_MODULE = "crewai"
QUESTION_FILE = "question.txt"
LOG_FILE = "crewai-run.log"
import argparse, itertools, json, os, pathlib, subprocess, sys, urllib.error, urllib.request

HARNESS_ROOT = os.path.expanduser(os.environ.get("HEIA_HARNESS_ROOT", "~/.hexaeight-harness"))
HARNESS_BIN = os.path.expanduser(os.environ.get("HEIA_HARNESS_BIN", "~/.heia/runtime/harness/hexaeight-engine"))
FW_HOME = os.path.expanduser(f"~/.heia/frameworks/{FW_KEY}")
SESS_DIR = pathlib.Path(os.environ.get(f"HEIA_{FW_KEY.upper()}_SESSIONS", os.path.join(FW_HOME, "sessions")))

# NOTHING LEAVES THE MACHINE UNASKED. Agent frameworks ship telemetry and tracing ON by default; under
# HexaEight the only way out is through the agent. Set before the framework loads.
for _k, _v in (("OTEL_SDK_DISABLED", "true"), ("LANGCHAIN_TRACING_V2", "false"), ("LANGSMITH_TRACING", "false"),
               ("AGNO_TELEMETRY", "false"), ("LOGFIRE_SEND_TO_LOGFIRE", "false"),
               ("CREWAI_DISABLE_TELEMETRY", "true"), ("CREWAI_TRACING_ENABLED", "false")):
    os.environ.setdefault(_k, _v)

# ---------------------------------------------------------------- HexaEight side: ask, never decide
_ids = itertools.count(1)


def _mcp():
    path = os.environ.get("HEIA_MCP_CONFIG", "")
    if not path or not os.path.isfile(path):
        return None
    srv = json.load(open(path))["mcpServers"]["heia"]
    return srv["url"], {k: v for k, v in (srv.get("headers") or {}).items() if v}


def service_call(peer, api, path, body, capability="", peer_url=""):
    args = {"peer": peer, "api": api, "method": "POST", "path": path, "body": body}
    if capability: args["capability"] = capability
    if peer_url: args["peer_url"] = peer_url
    return mcp_tool("service_call", args)


def mcp_tool(name, args):
    """One call to the agent's MCP server, with this turn's ticket. The agent decides; we only ask."""
    server = _mcp()
    if server is None:
        return {"error": "no MCP ticket in this turn (HEIA_MCP_CONFIG not set)"}
    url, headers = server
    req = urllib.request.Request(url, method="POST", headers={"Content-Type": "application/json", **headers},
                                 data=json.dumps({"jsonrpc": "2.0", "id": next(_ids), "method": "tools/call",
                                                  "params": {"name": name, "arguments": args}}).encode())
    try:
        with urllib.request.urlopen(req, timeout=90) as r:
            node = json.loads(r.read())
    except urllib.error.HTTPError as e:
        return {"error": f"MCP returned HTTP {e.code}"}
    except Exception as e:
        return {"error": f"{type(e).__name__}: {e}"}
    if "error" in node:
        return {"error": node["error"].get("message", "MCP error")}
    text = (((node.get("result") or {}).get("content") or [{}])[0]).get("text", "")
    try:
        return json.loads(text)
    except Exception:
        return {"text": text}


def _pointer(name):
    f = os.path.join(HARNESS_ROOT, "memories", name, "remote.json")
    return json.load(open(f)) if os.path.isfile(f) else None


def tool_log(tool, arg, result):
    """One line per tool call in the run log (stderr is the log — never the answer). Shows what the
    framework was actually given, so an answer the tool did not support can be told from one it did."""
    print(f"[tool] {tool}({arg!r}) -> {str(result)[:300]!r}", file=sys.stderr, flush=True)
    return result


def search_memory(name, query, top_k=5):
    return tool_log(f"search:{name}", query, _search_memory(name, query, top_k))


def _search_memory(name, query, top_k=5):
    p = _pointer(name)
    if p:   # served memory: the same call the harness makes (ServiceCallClient.Search)
        ans = service_call(p["agent"], p["api"], p.get("path") or "/heia/search",
                           {"query": query, "topK": top_k, "name": p.get("remote", name)},
                           p.get("capability", ""), p.get("peerUrl", ""))
        if "error" in ans:
            return f"could not search '{name}': {ans['error']}"
        inner = ans.get("result", ans)
        if isinstance(inner, dict) and inner.get("status") == "error":
            return f"'{name}' answered with an error: {inner.get('error')}"
        hits = (inner or {}).get("results")
        if hits is None:
            return f"'{name}' did not return results"
        return "\n\n".join(f"[{h.get('source') or h.get('document')}] {h.get('text', '')}" for h in hits) or "no matches"
    try:    # local memory: the harness binary, as its own OS process
        r = subprocess.run([HARNESS_BIN, "--memory-search", name, "--root", HARNESS_ROOT, "-p", query],
                           capture_output=True, text=True, timeout=120)
        return (r.stdout or r.stderr).strip()[:6000] or "no output"
    except Exception as e:
        return f"local search failed: {type(e).__name__}: {e}"


def memories():
    out, mdir = [], os.path.join(HARNESS_ROOT, "memories")
    for n in sorted(os.listdir(mdir)) if os.path.isdir(mdir) else []:
        p = _pointer(n)
        if p:
            out.append({"name": n, "kind": "served", "about": p.get("description", "")[:200]})
        elif os.path.isfile(os.path.join(mdir, n, "manifest.json")):
            try: about = json.load(open(os.path.join(mdir, n, "manifest.json"))).get("description", "") or ""
            except Exception: about = ""
            out.append({"name": n, "kind": "local", "about": about[:200]})
    return out


def who_am_i_text():
    r = tool_log("who_am_i", "", mcp_tool("who_am_i", {}))
    agent_name = r.get("agent") if isinstance(r, dict) else None
    if not agent_name:
        return f"could not ask the agent who it is: {r.get('error', r) if isinstance(r, dict) else r}"
    return (f"You are talking to agent {agent_name}; this {FRAMEWORK} agent answers behind it. Live weather and "
            f"BBC News come through HexaEight-verified services, documents from this machine's memories. "
            f"The user's own identity is verified by the agent at sign-in, but it is not revealed to this agent.")


def instructions():
    note = "" if _mcp() else "\nNOTE: no agent tools this turn (no MCP ticket). Say so if a tool is needed."
    return ("You are a helpful general assistant. Answer general knowledge, arithmetic, writing and conversation "
            "directly from what you know - no tool needed and never refuse those. Tools are ONLY for things you "
            "cannot know yourself: current weather (weather), current news (bbc_news), this machine's documents "
            "(list_memories, then memory_search), and who the user is talking to (who_am_i). When a fact comes "
            "from a tool, name the source. LIVE DATA IS NEVER REMEMBERED: for weather or news, call the tool "
            "again on EVERY request, even if the same question was answered earlier in this conversation, and "
            "report only what it returns this time. If the tool fails or returns nothing, say so - never fill "
            "in headlines, figures or facts yourself. Be concise." + note)


def load_transcript(sid):
    """This session's turns so far as [{role, content}], and a saver for the new turn."""
    SESS_DIR.mkdir(parents=True, exist_ok=True)
    f = SESS_DIR / f"{''.join(c for c in sid if c.isalnum() or c in '-_') or 'default'}.json"
    transcript = json.loads(f.read_text()) if f.exists() else []

    def save(question, answer):
        f.write_text(json.dumps(transcript + [{"role": "user", "content": question},
                                              {"role": "assistant", "content": answer}], indent=2))
    return transcript, save

# ---------------------------------------------------------------- CrewAI side: the work


def run(question, sid):
    from crewai import Agent, Task, Crew, Process, LLM
    from crewai.tools import tool

    @tool("weather")
    def weather(place: str) -> str:
        """Live current weather for one named place (a city, 'city, country', a postcode or 'lat,lon')."""
        return search_memory("weather", place)

    @tool("bbc_news")
    def bbc_news(query: str) -> str:
        """Current BBC News. Pass a topic (business, health, politics, science, sport, technology, top,
        uk, world) or a few words to find matching stories."""
        return search_memory("bbc-news", query)

    @tool("list_memories")
    def list_memories() -> str:
        """List the document memories on this machine, with what each contains."""
        return json.dumps(memories(), indent=1)

    @tool("memory_search")
    def memory_search(name: str, query: str) -> str:
        """Search one named memory (see list_memories) and return the matching passages."""
        return search_memory(name, query)

    @tool("who_am_i")
    def who_am_i() -> str:
        """Who the user is talking to: the HexaEight agent this crew runs behind. Use it for 'who am I',
        'who are you', 'what agent is this' and similar."""
        return who_am_i_text()

    token = os.environ.get("ANTHROPIC_AUTH_TOKEN", "")
    llm = LLM(model="anthropic/" + os.environ.get("ANTHROPIC_MODEL", ""),
              base_url=os.environ.get("ANTHROPIC_BASE_URL"), api_key=token,
              extra_headers={"Authorization": f"Bearer {token}"})
    transcript, save = load_transcript(sid)
    history = "\n".join(f'{t["role"]}: {t["content"]}' for t in transcript)
    agent = Agent(role="Helpful general assistant",
                  goal="Answer whatever the user asks, helpfully and concisely.",
                  backstory=instructions(), llm=llm,
                  tools=[weather, bbc_news, list_memories, memory_search, who_am_i], verbose=False)
    task = Task(description=f"Conversation so far:\n{history or '(none)'}\n\nNew message: {question}\n\n"
                            f"Answer it. Use a tool only if the answer depends on live data or on "
                            f"this machine's documents; otherwise answer directly.",
                expected_output="A concise, helpful answer; sources named for any tool-derived facts.", agent=agent)
    answer = str(Crew(agents=[agent], tasks=[task], process=Process.sequential, verbose=False).kickoff()).strip()
    save(question, answer)
    return answer


def _ensure_framework():
    """Re-launch under this framework's environment when this interpreter does not have it."""
    import importlib.util
    if importlib.util.find_spec(FW_MODULE) is not None:
        return
    candidates = [os.environ.get(f"HEIA_{FW_KEY.upper()}_PYTHON", ""), os.path.join(FW_HOME, ".venv", "bin", "python3")]
    for py in candidates:
        if py and os.path.isfile(py) and os.path.realpath(py) != os.path.realpath(sys.executable):
            os.execv(py, [py, os.path.abspath(__file__)] + sys.argv[1:])
    sys.exit(f"{FRAMEWORK} is not installed for this agent. Run: hexaeight-activate enable {FW_KEY}")


def main():
    _ensure_framework()
    ap = argparse.ArgumentParser()
    ap.add_argument("--question-file", default=QUESTION_FILE)
    ap.add_argument("--session", default=os.environ.get("HEIA_WORK_SESSION", "default"))
    a = ap.parse_args()
    question = pathlib.Path(a.question_file).read_text().strip()

    # THE ANSWER IS THE ONLY OUTPUT. The harness captures stdout AND stderr into one result, so the
    # framework's own output (banners, warnings, exit-time notices) goes to the log file in the working
    # folder instead — at the descriptor level, so output written straight to fd 1/2 is caught too.
    answer_fd = os.dup(1)
    log = open(LOG_FILE, "a")
    os.dup2(log.fileno(), 1)
    os.dup2(log.fileno(), 2)
    try:
        answer = run(question, a.session)
    except Exception as e:
        answer = f"The {FRAMEWORK} agent failed: {type(e).__name__}: {e} (details in {LOG_FILE})"
        import traceback; traceback.print_exc()
    sys.stdout.flush(); sys.stderr.flush()
    # THE FRAMEWORK SPEAKS FOR ITSELF. The attribution is this runner's own statement — HexaEight renders
    # the text as it is and vouches for nothing inside it; its guarantee is only that THIS approved,
    # sha-pinned file is what ran.
    os.write(answer_fd, (f"# Answer\n> Answered by {FRAMEWORK}\n\n{answer}\n").encode())
    # Skip interpreter exit hooks: frameworks print exit-time notices there.
    os._exit(0)


if __name__ == "__main__":
    main()
