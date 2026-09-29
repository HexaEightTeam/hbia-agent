#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────────────────────────
# HexaEight — install everything with one command, on a fresh Linux (or WSL) machine.
#
#     curl -fsSL https://raw.githubusercontent.com/HexaEightTeam/hbia-agent/main/install.sh | bash
#
# RUN IT TWICE. The first run prepares the machine and the licence folder, then stops: activating
# the licence is yours alone (a password and a QR approval on your phone). Run the same command
# again and it installs the router, the agent and the workspace, asks for your model provider's key
# (or an existing router's address), and finishes with the workspace URL.
#
# Safe to re-run at any point: every step checks whether it is already done.
# Layout (the documented one): ~/hbia-agent  licence only · ~/heia-router · ~/heia-agent
#
# THE GATEWAY. By default the last step makes the install reachable from anywhere: it installs
# cloudflared into ~/.heia/bin, lets the agent publish itself (registry + tunnel), and puts the
# workspace behind an HTTPS tunnel. To keep everything on this machine only:
#
#     curl -fsSL …/install.sh | bash -s -- --skip-gateway
# ──────────────────────────────────────────────────────────────────────────────────────────────────
set -u

SKIP_GATEWAY=0
for arg in "$@"; do
  case "$arg" in
    --skip-gateway) SKIP_GATEWAY=1 ;;
    -h|--help) sed -n '2,20p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf '  unknown option: %s  (known: --skip-gateway)\n' "$arg"; exit 1 ;;
  esac
done

LIC="$HOME/hbia-agent"        # the licence: env-file + hexaeight.mac, nothing else. Never move it.
ROUTER="$HOME/heia-router"
AGENT="$HOME/heia-agent"
STATE="$HOME/.heia/install.state"
TTY=/dev/tty

# ── output ────────────────────────────────────────────────────────────────────────────────────────
if [ -t 1 ]; then B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; C=$'\e[36m'; N=$'\e[0m'; else B= G= Y= R= C= N=; fi
# A SPINNER for the slow, silent steps, so the terminal never looks dead: `spin "what"` before the
# step; any next line of output (ok, note, warn, die, ask, step) stops it.
SPIN_PID=""
spin_done() { if [ -n "$SPIN_PID" ]; then kill "$SPIN_PID" 2>/dev/null; while kill -0 "$SPIN_PID" 2>/dev/null; do sleep 0.05; done; SPIN_PID=""; printf '\r\033[K'; fi; }
spin() {
  spin_done
  if [ -t 1 ]; then
    ( s='|/-\'; t=0; while :; do printf '\r  %s %s ... %ss ' "${s:$((t % 4)):1}" "$1" "$((t / 5))"; t=$((t + 1)); sleep 0.2; done ) &
    SPIN_PID=$!; disown "$SPIN_PID" 2>/dev/null
  else printf '  %s ...\n' "$1"; fi
}
trap spin_done EXIT
step() { spin_done; printf '\n%s━━ %s%s\n' "$B$C" "$*" "$N"; }
ok()   { spin_done; printf '  %s✓%s %s\n' "$G" "$N" "$*"; }
note() { spin_done; printf '  %s\n' "$*"; }
warn() { spin_done; printf '  %s!%s %s\n' "$Y" "$N" "$*"; }
die()  { spin_done; printf '\n  %s✗ %s%s\n\n' "$R" "$*" "$N"; exit 1; }

# Questions go to the TERMINAL, not stdin: under `curl | bash` stdin is this script.
ask() {   # ask "Prompt" [default] -> REPLY
  local p="$1" d="${2:-}"
  spin_done
  [ -n "$d" ] && p="$p [$d]"
  printf '  %s%s:%s ' "$B" "$p" "$N" > "$TTY"
  IFS= read -r REPLY < "$TTY" || REPLY=""
  [ -z "$REPLY" ] && REPLY="$d"
}
state_get() { [ -f "$STATE" ] && sed -n "s/^$1=//p" "$STATE" | tail -1; }
state_set() { mkdir -p "$(dirname "$STATE")"; touch "$STATE"; grep -v "^$1=" "$STATE" > "$STATE.tmp"; echo "$1=$2" >> "$STATE.tmp"; mv "$STATE.tmp" "$STATE"; }
activate() { hexaeight-activate "$@" < /dev/null; }            # never lets a command hold the terminal
activate_tty() { hexaeight-activate "$@" < "$TTY"; }           # for Activate's own interactive pickers
# STARTS RUN DETACHED. `restart agent` starts the agent's helper services (memory, browser, codememory)
# itself and the agent adopts them. Started from this terminal, they die with it — and with them the
# engine's command check ("execution-policy service unavailable"). Run in their own session (setsid;
# nohup where there is none), and waited for, so everything they start outlives this installer.
if command -v setsid >/dev/null 2>&1; then activate_bg() { setsid -w hexaeight-activate "$@" < /dev/null; }
else activate_bg() { nohup hexaeight-activate "$@" < /dev/null; }; fi
# START THE AGENT, and make sure it stays up. It opens :8770 only after its reach step (up to about a
# minute when Cloudflare gives no address and it falls back to the relay), so the wait is long. And one
# start in a while dies at once — "engines.he did not decrypt" (a bad key drawn on that start; seen on
# the Mac and on WSL, the next start is fine) — so a crash is simply started again, up to 3 times.
agent_start() {   # agent_start "what the spinner says" -> 0 once :8770 answers
  local try i why
  for try in 1 2 3; do
    spin "$1"
    ( cd "$AGENT" && activate_bg restart agent > /tmp/heia-agent-start.log 2>&1 )
    for i in $(seq 1 90); do
      listening 8770 && return 0
      pgrep -f "$AGENT/$ABIN\$" > /dev/null 2>&1 || break   # gone: it crashed on start
      sleep 2
    done
    why="$(grep -a -m1 'Unhandled exception' "$AGENT/agent.log" 2>/dev/null | cut -c1-140)"
    [ "$try" -lt 3 ] && note "the agent did not come up (${why:-no answer on :8770}) — starting it again ($((try + 1))/3)"
  done
  return 1
}

# ── the platform: Linux (x86_64, incl. WSL) or macOS (Apple Silicon). Names and tools differ. ──
OS="$(uname -s)"; ARCH="$(uname -m)"
if [ "$OS" = "Darwin" ]; then PLAT=osx-arm64; else PLAT=linux-x64; fi
ABIN="hexaeight-agent-$PLAT"; RBIN="hexaeight-router-$PLAT"
inode()     { if [ "$OS" = "Darwin" ]; then stat -f %i "$1"; else stat -c %i "$1"; fi; }
listening() { if [ "$OS" = "Darwin" ]; then lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; else ss -ltn 2>/dev/null | grep -q ":$1 "; fi; }

# hardlink the licence into a component folder (ln, never cp) and prove it by inode
link_licence() {
  local d="$1" f
  mkdir -p "$d"
  for f in env-file hexaeight.mac; do
    if [ ! -e "$d/$f" ]; then
      # macOS: Activate locks the licence files immutable (chflags uchg), and an immutable file refuses
      # new hardlinks. Unlock for the one link, then lock again — a hardlink is the same file, so the
      # lock covers every folder's name for it. (Linux: an ordinary user cannot set that flag.)
      local relock=0 rc
      if [ "$OS" = "Darwin" ] && stat -f %Sf "$LIC/$f" 2>/dev/null | grep -q uchg; then
        chflags nouchg "$LIC/$f" && relock=1
      fi
      ln "$LIC/$f" "$d/$f"; rc=$?
      [ "$relock" = 1 ] && chflags uchg "$LIC/$f"
      [ "$rc" = 0 ] || die "could not hardlink $f into $d"
    fi
    [ "$(inode "$LIC/$f")" = "$(inode "$d/$f")" ] || die "$d/$f is not a hardlink of $LIC/$f — do not copy licence files"
  done
  ok "licence hardlinked into $d (same inode)"
}
wait_port() { local p="$1" i; for i in $(seq 1 "${2:-60}"); do listening "$p" && return 0; sleep 1; done; return 1; }

# ── macOS only: the two steps whose absence looks like a working install in which nothing answers ──
# 1. A downloaded binary must carry a valid signature or macOS kills it ("Killed: 9", reads as a crash).
#    Ad-hoc re-sign (`-s -`: no developer account) anything that does not verify; leave good ones alone.
mac_sign() {
  local f
  for f in "$@"; do
    [ -f "$f" ] || continue
    file "$f" 2>/dev/null | grep -q 'Mach-O' || continue
    xattr -d com.apple.quarantine "$f" 2>/dev/null || true
    codesign --verify --strict "$f" >/dev/null 2>&1 && continue
    codesign -s - -f "$f" >/dev/null 2>&1 && codesign --verify --strict "$f" >/dev/null 2>&1 \
      || die "could not sign $f — macOS will refuse to run it"
    ok "signed $(basename "$f") (ad-hoc)"
  done
}
# 2. The jail must hide the licence FILES, not the agent's folder: on macOS the engine starts INSIDE
#    that folder and dies with EPERM if the folder itself is masked. The sandbox matches REAL paths
#    only (/tmp is /private/tmp, a folder can have two names), so each file is listed by its real path
#    and by the path the agent uses. Written with macOS's own JavaScript — no python.
mac_mask() {
  local cfg="$AGENT/hexaeight-agent.json" real paths=() f js
  real="$(cd "$AGENT" && pwd -P)"
  for f in env-file hexaeight.mac agent.uuid; do
    paths+=("$real/$f"); [ "$real" = "$AGENT" ] || paths+=("$AGENT/$f")
  done
  cp -p "$cfg" "$cfg.bak_$(date +%Y%m%d_%H%M%S)"
  js="$(mktemp -t heia-mask).js"
  cat > "$js" <<'EOF'
ObjC.import('Foundation');
function run(argv) {
  var p = argv[0];
  var s = $.NSString.stringWithContentsOfFileEncodingError(p, $.NSUTF8StringEncoding, null);
  if (!s) throw new Error('cannot read ' + p);
  var d = JSON.parse(s.js);
  d.jail = { enabled: true, mask: argv.slice(1) };
  if (!$(JSON.stringify(d, null, 2) + '\n').writeToFileAtomicallyEncodingError(p, true, $.NSUTF8StringEncoding, null))
    throw new Error('cannot write ' + p);
  return 'ok';
}
EOF
  osascript -l JavaScript "$js" "$cfg" "${paths[@]}" >/dev/null || die "could not set the jail mask in $cfg"
  # PROVE BOTH HALVES: the licence is unreadable inside the sandbox, and an engine still starts there.
  local P="(version 1)(allow default)(deny file-read*"
  for f in "${paths[@]}"; do P="$P (subpath \"$f\")"; done
  P="$P)"
  if /usr/bin/sandbox-exec -p "$P" /bin/cat "$AGENT/env-file" >/dev/null 2>&1; then
    die "the licence is still readable inside the sandbox — the mask is wrong; see $cfg"
  fi
  /usr/bin/sandbox-exec -p "$P" /bin/echo ok >/dev/null 2>&1 || die "nothing can run inside the sandbox — the mask covers too much"
  ok "licence files hidden from every engine turn; engines can still start"
}

printf '\n%sHexaEight — one-command install%s\n' "$B" "$N"
[ -r "$TTY" ] || die "no terminal to ask questions on. Run this from an interactive terminal."

# ══ 1 · the machine ════════════════════════════════════════════════════════════════════════════════
step "1 · Checking this machine"
case "$OS/$ARCH" in
  Linux/x86_64)
    case "$HOME" in /mnt/*) die "your home is under /mnt — keep HexaEight on the Linux filesystem.";; esac
    ok "Linux x86_64 ($(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")), $(nproc) cores" ;;
  Darwin/arm64)
    ok "macOS $(sw_vers -productVersion) on Apple Silicon, $(sysctl -n hw.ncpu) cores" ;;
  Darwin/*) die "Intel Macs have no published build — Apple Silicon only." ;;
  *)        die "no published build for $OS $ARCH — Linux x86_64 or Apple Silicon macOS only." ;;
esac
command -v curl >/dev/null || die "curl is missing — install it, then run this again."
if [ "$OS" = "Darwin" ]; then MEMGB=$(( $(sysctl -n hw.memsize) / 1073741824 )); else MEMGB=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1048576 )); fi
[ "$MEMGB" -lt 4 ] && warn "only ${MEMGB} GB of memory — the router, agent and workspace together are tight below 4 GB."

# .NET goes into ~/.dotnet (no sudo), so every shell needs these two lines — written once to the
# shell's own startup files (bash on Linux; zsh on macOS, login and interactive).
export DOTNET_ROOT="$HOME/.dotnet"
export PATH="$HOME/.dotnet:$HOME/.dotnet/tools:$PATH"
if [ "$OS" = "Darwin" ]; then PROFILES="$HOME/.zprofile $HOME/.zshrc"; RCFILE="~/.zshrc"; else PROFILES="$HOME/.bashrc"; RCFILE="~/.bashrc"; fi
for prof in $PROFILES; do
  if ! grep -q "# >>> hexaeight >>>" "$prof" 2>/dev/null; then
    cat >> "$prof" <<'EOF'

# >>> hexaeight >>>  (.NET and hexaeight-activate live in ~/.dotnet)
export DOTNET_ROOT="$HOME/.dotnet"
export PATH="$HOME/.dotnet:$HOME/.dotnet/tools:$PATH"
# <<< hexaeight <<<
EOF
    ok "added .NET to $(basename "$prof") (new terminals find hexaeight-activate)"
  fi
done

# PREREQUISITES, installed by the machine's administrator — this installer never uses sudo.
#   Linux: bubblewrap confines every engine turn; libicu is the Unicode library .NET needs.
#   macOS: nothing — the sandbox (sandbox-exec) and ICU are part of the OS.
need=""
if [ "$OS" = "Linux" ]; then
  [ -x /usr/bin/bwrap ] || need="$need bubblewrap"
  ldconfig -p 2>/dev/null | grep -q 'libicuuc\.so' || need="$need libicu-dev"
fi
if [ -n "$need" ]; then
  cat <<EOF

  ${B}Prerequisites missing:${N}$need
  These are system packages, installed once by the machine's administrator:

      ${B}sudo apt-get install -y$need${N}          (Debian / Ubuntu)
      ${B}sudo dnf install -y$need${N}              (Fedora / RHEL — libicu instead of libicu-dev)

  Then run this installer again.

EOF
  exit 0
fi
if [ "$OS" = "Darwin" ]; then ok "prerequisites: none needed on macOS (sandbox-exec is built in)"
else ok "prerequisites present (bubblewrap, libicu)"; fi

if ! command -v dotnet >/dev/null || ! dotnet --list-runtimes 2>/dev/null | grep -q "Microsoft.NETCore.App 8\."; then
  spin "Installing .NET 8 into ~/.dotnet"
  curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh || die "could not download the .NET installer"
  bash /tmp/dotnet-install.sh --channel 8.0 --install-dir "$HOME/.dotnet" > /tmp/dotnet-install.log 2>&1 || die ".NET install failed — see /tmp/dotnet-install.log"
fi
ok ".NET $(dotnet --version 2>/dev/null)"
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1

spin "Installing / updating the HexaEight.Activate tool"
if dotnet tool list -g 2>/dev/null | grep -qi '^hexaeight.activate '; then
  dotnet tool update -g HexaEight.Activate > /dev/null 2>&1 || true
else
  dotnet tool install -g HexaEight.Activate > /dev/null 2>&1 || die "could not install the HexaEight.Activate tool"
fi
ok "hexaeight-activate $(dotnet tool list -g | awk 'tolower($1)=="hexaeight.activate"{print $2}')"

# ══ 2 · the licence — yours ════════════════════════════════════════════════════════════════════════
step "2 · Licence"
mkdir -p "$LIC"
OWNER="$(state_get owner)"
if [ -z "$OWNER" ]; then
  note "The owner is the email you sign in to the workspace with — the one your Authenticator vault uses."
  while :; do ask "Owner email"; case "$REPLY" in *@*.*) break;; *) warn "that does not look like an email";; esac; done
  OWNER="$REPLY"; state_set owner "$OWNER"
fi
ok "owner: $OWNER"

if [ ! -f "$LIC/env-file" ] || [ ! -f "$LIC/hexaeight.mac" ]; then
  cat <<EOF

  ${B}Now activate the licence — this step is yours.${N}
  You need: the HexaEight Authenticator on your phone with your email vault, your licence code,
  and a name for this agent. It asks for them and shows a QR code to approve on your phone.

      ${B}source ${RCFILE}${N}
      ${B}cd ~/hbia-agent && hexaeight-activate newtoken${N}

  The first line matters: it puts the tool this installer just added (~/.dotnet/tools) first on
  your PATH. Without it the terminal may find another program of the same name — on WSL, a
  Windows one — and fail. (A new terminal works too.)
  When it says the licence works, run this installer again — it carries on from here.

EOF
  exit 0
fi

NAME="$(cd "$LIC" && activate verify-license 2>&1 | sed -n 's/^ *Identity: *//p' | head -1)"
( cd "$LIC" && activate verify-license 2>&1 | grep -q "installed and working" ) \
  || die "the licence in ~/hbia-agent does not verify. Run: cd ~/hbia-agent && hexaeight-activate verify-license"
ok "licence verified — this agent is ${B}$NAME${N}"
state_set identity "$NAME"

# ONE OWNER PER SERVICE. Once installed, the service manager (systemd --user / launchd) runs router,
# agent and workspace, and restarts them. This installer starts its own copies while it works. Two
# copies of one service fight over its port and the manager restarts the loser forever — seen: 1,373
# router restarts in one night, each a licence check, and each agent restart a new quick tunnel until
# Cloudflare refused this network (HTTP 429). So on a re-run the managed copies are STOPPED here (still
# enabled for the next login), and handed back to the manager at the very end (step 7).
UNITS_L="$HOME/.config/systemd/user"; UNITS_M="$HOME/Library/LaunchAgents"
managed_stop() {
  if [ "$OS" = "Darwin" ]; then
    for f in "$UNITS_M"/com.hexaeight.*.plist; do [ -f "$f" ] && launchctl unload "$f" > /dev/null 2>&1; done
  elif command -v systemctl > /dev/null 2>&1 && ls "$UNITS_L"/hexaeight-*.service > /dev/null 2>&1; then
    systemctl --user stop hexaeight-workspace.service hexaeight-agent.service hexaeight-router.service > /dev/null 2>&1
  fi
  true
}
managed_stop

# ONLY WHAT MOVED. releases.json (in the hbia-agent repo) names the current release of every component
# and the SHA-256 of each platform's file; Activate's install-* commands read the same file. A re-run
# compares what is here with it and fetches only the components that differ — a UI fix downloads the
# 23 MB workspace, not the 180 MB agent. A first install is unchanged, and records what it put down.
REL="$(curl -fsSL --max-time 20 https://raw.githubusercontent.com/HexaEightTeam/hbia-agent/main/releases.json 2>/dev/null || true)"
rel_top() {     # rel_top <component> <key>          -> e.g. tag, repo
  printf '%s\n' "$REL" | awk -v c="\"$1\":" -v k="\"$2\":" \
    '$1==c{inc=1} inc && index($0,k){s=$0; sub(/^[^:]*: *"/,"",s); sub(/".*/,"",s); print s; exit}'
}
rel_asset() {   # rel_asset <component> <rid> <file|sha256>
  printf '%s\n' "$REL" | awk -v c="\"$1\":" -v r="\"$2\":" -v k="\"$3\":" \
    '$1==c{inc=1} inc && $1==r{inr=1} inr && index($0,k){s=$0; sub(/^[^:]*: *"/,"",s); sub(/".*/,"",s); print s; exit}'
}
sha_of() {
  if [ "$OS" = "Darwin" ]; then shasum -a 256 "$1" 2>/dev/null | awk '{print toupper($1)}'
  else sha256sum "$1" 2>/dev/null | awk '{print toupper($1)}'; fi
}
UPDATES=""
RERUN=0; [ -f "$AGENT/$ABIN" ] && RERUN=1       # an install already here: this run checks for updates
updated() { UPDATES="${UPDATES}  ${G}↑${N} $1"$'\n'; }
# Is the file here the published one? Same bytes — or, on macOS, where signing a binary changes its
# bytes, the release this installer recorded when it put the file there. No record on a Mac (installed
# by an earlier version of this script): taken as current and recorded, rather than fetched again.
is_current() {   # is_current <component> <file> <state key>
  local pub tag; pub="$(rel_asset "$1" "$PLAT" sha256)"; tag="$(rel_top "$1" tag)"
  [ -n "$pub" ] || return 0                                 # releases.json unreachable: change nothing
  if [ "$(sha_of "$2")" = "$pub" ]; then state_set "$3" "$tag"; return 0; fi
  if [ "$OS" = "Darwin" ]; then
    [ "$(state_get "$3")" = "$tag" ] && return 0
    [ -z "$(state_get "$3")" ] && { state_set "$3" "$tag"; return 0; }
  fi
  return 1
}
# An engine is a file under ~/.heia/runtime, fetched and verified here (Activate fetches engines only
# together with a new agent). Swapped by RENAME — a running engine keeps its old file until restarted.
upgrade_engine() {   # upgrade_engine <component> <folder> <local name>
  local tgt="$HOME/.heia/runtime/$2/$3" pub tag file repo
  [ -f "$tgt" ] || return 0
  is_current "$1" "$tgt" "$1" && return 0
  pub="$(rel_asset "$1" "$PLAT" sha256)"; tag="$(rel_top "$1" tag)"; file="$(rel_asset "$1" "$PLAT" file)"
  repo="$(rel_top "$1" repo)"
  spin "Updating the $2 engine to $tag"
  if ! curl -fsSL --max-time 900 -o "$tgt.partial" "https://github.com/$repo/releases/download/$tag/$file"; then
    warn "could not download the $2 engine $tag — the installed one stays"; return 0
  fi
  if [ "$(sha_of "$tgt.partial")" != "$pub" ]; then
    mv "$tgt.partial" "$tgt.partial.rejected"
    warn "the $2 engine download did not match its published hash — not installed (kept as $tgt.partial.rejected)"
    return 0
  fi
  chmod +x "$tgt.partial"
  mv "$tgt" "$tgt.prev_$(date +%Y%m%d_%H%M%S)" && mv "$tgt.partial" "$tgt"
  [ "$OS" = "Darwin" ] && mac_sign "$tgt"
  state_set "$1" "$tag"; updated "$2 engine → $tag"; ok "$2 engine updated to $tag"
}

# ══ 3 · the router ═════════════════════════════════════════════════════════════════════════════════
step "3 · Model router"
MODE="$(state_get router_mode)"
if [ -z "$MODE" ]; then
  note "Agents never hold model keys — a router does. Choose one:"
  note "  1. Run a router here with my own provider key (AWS Bedrock, z.ai, Azure AI Foundry, Azure OpenAI, OpenAI, OpenRouter, or any compatible URL)"
  note "  2. Use a router that already runs elsewhere (I have its name and URL)"
  ask "1 or 2" "1"; [ "$REPLY" = "2" ] && MODE=remote || MODE=own
  state_set router_mode "$MODE"
fi

if [ "$MODE" = own ]; then
  link_licence "$ROUTER"
  if [ ! -f "$ROUTER/$RBIN" ]; then
    spin "Downloading the router"
    activate install-router --dir "$ROUTER" > /tmp/heia-install-router.log 2>&1 \
      || die "install-router failed — see /tmp/heia-install-router.log"
    [ "$OS" = "Darwin" ] && mac_sign "$ROUTER/$RBIN"
    state_set router "$(rel_top router tag)"
    ok "router installed in $ROUTER"
  elif is_current router "$ROUTER/$RBIN" router; then
    ok "router installed in $ROUTER — current ($(state_get router))"
  else
    T="$(rel_top router tag)"; spin "Updating the router to $T"
    RF=""; [ "$OS" = "Darwin" ] && RF="--force"      # a signed copy of an older release, recorded as ours
    if activate install-router --dir "$ROUTER" $RF > /tmp/heia-install-router.log 2>&1; then
      [ "$OS" = "Darwin" ] && mac_sign "$ROUTER/$RBIN"
      state_set router "$T"; updated "router → $T"; ok "router updated to $T (the previous one is kept beside it)"
    else
      warn "the router was not updated — see /tmp/heia-install-router.log; the installed one keeps running"
    fi
  fi

  # THE PROVIDERS. An ANTHROPIC-format route is REQUIRED: the HexaEight harness engines (chat,
  # missions, coding) and the external framework runners speak it, so the install cannot work without
  # one. A provider that speaks only OpenAI still qualifies — the router converts Anthropic to OpenAI on
  # the way ("translate: openai"). OPENAI-format routes are optional ADD-ONS, for engines you bring that
  # speak OpenAI; any number of them can be added.
  # Bedrock, z.ai and an Anthropic URL go through Activate's own picker (it knows Bedrock's Converse
  # translation and can list their models). Everything else is written here — the picker writes bearer
  # auth only, and Azure wants its key in an "api-key" header. Activate keeps those lines when it
  # rewrites the file later. Keys are read without echo and written only into upstreams.yaml (0600).
  # (anchored: the template's commented examples must never count)
  has_shape() { grep -q "^[[:space:]]*shape: *\"$1\"" "$ROUTER/upstreams.yaml" 2>/dev/null; }
  has_match() { grep -qF "match:     \"$1\"" "$ROUTER/upstreams.yaml" 2>/dev/null; }
  uniq_match() { local m="$1" i=2; while has_match "$m"; do m="$1$i"; i=$((i+1)); done; printf '%s' "$m"; }
  read_key() {   # read_key "label" -> KEY, not echoed
    printf '  %sPaste your %s (it is not shown):%s ' "$B" "$1" "$N" > "$TTY"
    stty -echo < "$TTY" 2>/dev/null; IFS= read -r KEY < "$TTY"; stty echo < "$TTY" 2>/dev/null; printf '\n' > "$TTY"
    [ -n "$KEY" ] || die "no key given"
  }
  picker() {     # picker <provider#> <fields or ""> <dialects> — KEY must be set; default tag
    local a
    if [ -n "$2" ]; then a="$(printf '%s\n\n%s\n%s\n%s\n' "$1" "$2" "$3" "$KEY")"
    else                 a="$(printf '%s\n\n%s\n%s\n' "$1" "$3" "$KEY")"; fi
    ( cd "$ROUTER" && printf '%s\n' "$a" | hexaeight-activate upstreams >> /tmp/heia-upstreams.log 2>&1 )
    a=""
  }
  write_entry() {   # write_entry <match> <shape> <translate or ""> <url> <bearer|api-key> — KEY must be set
    local m; m="$(uniq_match "$1")"
    ( umask 077
      [ -n "$(tail -c 1 "$ROUTER/upstreams.yaml")" ] && echo
      printf '  - match:     "%s"\n    shape:     "%s"\n' "$m" "$2"
      [ -n "$3" ] && printf '    translate: "%s"\n' "$3"
      printf '    url:       "%s"\n' "$4"
      if [ "$5" = api-key ]; then printf '    auth:      "none"\n    secret:    ""\n    headers:\n      api-key: "%s"\n' "$KEY"
      else                        printf '    auth:      "bearer"\n    secret:    "%s"\n' "$KEY"; fi
      true ) >> "$ROUTER/upstreams.yaml"
    printf '  + %s  →  %s\n' "$m" "$4" >> /tmp/heia-upstreams.log
  }
  # Per provider: its name, its route tag, where its OpenAI-format endpoint is, and how the key is sent.
  # Azure (Foundry and Azure OpenAI) use the v1 path: the model/deployment goes in the body, no api-version.
  pname() { case "$P" in bedrock) echo "AWS Bedrock";; zai) echo "z.ai";; foundry) echo "Azure AI Foundry";;
    azure) echo "Azure OpenAI";; openai) echo "OpenAI";; openrouter) echo "OpenRouter";; *) echo "that endpoint";; esac; }
  ptag()  { case "$P" in bedrock) echo aws;; zai) echo zai;; foundry) echo foundry;; azure) echo azure;;
    openai) echo oai;; openrouter) echo or;; *) echo url;; esac; }
  pauth() { case "$P" in foundry|azure) echo api-key;; *) echo bearer;; esac; }
  poai()  { case "$P" in
    bedrock)    echo "https://bedrock-runtime.$REG.amazonaws.com/openai/v1/chat/completions";;
    zai)        echo "https://api.z.ai/api/coding/paas/v4/chat/completions";;
    foundry)    echo "https://$RES.services.ai.azure.com/openai/v1/chat/completions";;
    azure)      echo "https://$RES.openai.azure.com/openai/v1/chat/completions";;
    openai)     echo "https://api.openai.com/v1/chat/completions";;
    openrouter) echo "https://openrouter.ai/api/v1/chat/completions";;
    *)          echo "$URL";; esac; }
  # The questions each provider needs. <req> also asks for the model where there is no list to pick from.
  pfields() {
    case "$P" in
      bedrock) ask "AWS region" "us-east-1"; REG="$REPLY" ;;
      foundry|azure)
        if [ "$P" = foundry ]; then ask "Foundry resource name (the <name> in <name>.services.ai.azure.com)"
        else ask "Azure OpenAI resource name (the <name> in <name>.openai.azure.com)"; fi
        [ -n "$REPLY" ] || die "no resource name given"
        RES="${REPLY#*://}"; RES="${RES%%.*}"   # a pasted URL is fine: keep only <name>
        [ "$1" = req ] && { ask "Deployment name (the model you deployed, e.g. gpt-5-mini, Kimi-K2.5)"; [ -n "$REPLY" ] || die "no deployment name given"; DEP="$REPLY"; } ;;
      openai)     [ "$1" = req ] && { ask "Model id" "gpt-5-mini"; DEP="$REPLY"; } ;;
      openrouter) [ "$1" = req ] && { ask "Model id" "moonshotai/kimi-k2"; DEP="$REPLY"; } ;;
      anturl)  ask "Its full URL (e.g. https://host/v1/messages)"; [ -n "$REPLY" ] || die "no URL given"; URL="$REPLY" ;;
      oaiurl)  ask "Its full URL (e.g. https://host/v1/chat/completions)"; [ -n "$REPLY" ] || die "no URL given"; URL="$REPLY"
               [ "$1" = req ] && { ask "Model id"; [ -n "$REPLY" ] || die "no model given"; DEP="$REPLY"; } ;;
    esac
    true
  }

  if ! has_shape anthropic; then
    # A fresh router has no upstreams.yaml yet — Activate's picker creates it on its first write. The
    # routes written here need it first, so start it the way Activate does: the list key, 0600.
    if [ -f "$ROUTER/upstreams.yaml" ]; then
      cp -p "$ROUTER/upstreams.yaml" "$ROUTER/upstreams.yaml.bak_$(date +%Y%m%d_%H%M%S)"
    else
      ( umask 077; printf 'upstreams:\n\n' > "$ROUTER/upstreams.yaml" )
    fi
    : > /tmp/heia-upstreams.log
    note "Where are your models? The engines speak the Anthropic format; for 5 to 8 the router converts."
    note "  1. AWS Bedrock        — one AWS key reaches Claude, GLM, Kimi, DeepSeek, Qwen and more"
    note "  2. z.ai               — GLM models"
    note "  3. Another endpoint that speaks the Anthropic API (you give its URL)"
    note "  4. Azure AI Foundry   — a model deployed in Foundry (GPT, Kimi, DeepSeek, Llama and more)"
    note "  5. Azure OpenAI       — a model deployed in Azure OpenAI"
    note "  6. OpenAI"
    note "  7. OpenRouter"
    note "  8. Another endpoint that speaks the OpenAI API (you give its URL)"
    ask "1 to 8" "1"
    case "$REPLY" in
      2) P=zai;; 3) P=anturl;; 4) P=foundry;; 5) P=azure;; 6) P=openai;; 7) P=openrouter;; 8) P=oaiurl;; *) P=bedrock;;
    esac
    REG=""; URL=""; RES=""; DEP=""
    pfields req
    read_key "$(pname) API key"
    case "$P" in
      bedrock) picker 1 "$REG" 1 ;;
      zai)     picker 2 ""     1 ;;
      anturl)  picker 6 "$URL" 1 ;;
      *)       write_entry "*-ant-$(ptag)" anthropic openai "$(poai)" "$(pauth)"
               # no model list to pick from here — the deployment / model id given above is the model
               [ -n "$(state_get model)" ] || state_set model "$DEP" ;;
    esac
    has_shape anthropic || die "the provider was not added — see /tmp/heia-upstreams.log"
    PREV_P="$P"; PREV_REG="$REG"; PREV_RES="$RES"; PREV_URL="$URL"; PREV_KEY="$KEY"; KEY=""

    # THE ADD-ONS: OpenAI-format routes for engines you bring. As many as wanted, any provider.
    ask "Add routes for engines that speak the OpenAI format? (y/N)" "N"
    while :; do
      case "$REPLY" in y|Y|yes|YES) ;; *) break ;; esac
      note "Which provider? (OpenAI format)"
      note "  1. AWS Bedrock        — the openai.gpt-oss-* models"
      note "  2. z.ai"
      note "  3. Azure AI Foundry"
      note "  4. Azure OpenAI"
      note "  5. OpenAI"
      note "  6. OpenRouter"
      note "  7. Another endpoint that speaks the OpenAI API (you give its URL)"
      ask "1 to 7" "1"
      case "$REPLY" in
        2) P=zai;; 3) P=foundry;; 4) P=azure;; 5) P=openai;; 6) P=openrouter;; 7) P=oaiurl;; *) P=bedrock;;
      esac
      REG=""; URL=""; RES=""; DEP=""; SAME=""
      if [ "$P" = "$PREV_P" ] && [ "$P" != oaiurl ]; then
        ask "The same $(pname) as the first route, with the same key? (Y/n)" "Y"
        case "$REPLY" in n|N|no|NO) ;; *) SAME=1; REG="$PREV_REG"; RES="$PREV_RES"; URL="$PREV_URL"; KEY="$PREV_KEY" ;; esac
      fi
      [ -n "$SAME" ] || { pfields add; read_key "$(pname) API key"; }
      write_entry "*-oai-$(ptag)" openai "" "$(poai)" "$(pauth)"
      KEY=""
      ask "Add another? (y/N)" "N"
    done
    PREV_KEY=""
    grep -o '+ \*-[a-z]*-[^ ]*  →  .*' /tmp/heia-upstreams.log | sed 's/^/  /'
  fi
  ok "provider configured (Anthropic format — what the engines speak$(has_shape openai && echo '; OpenAI format too'))"
  # OPAQUE CALLERS PERMITTED — the router's default, and how the reference install runs: an agent may
  # decline to name a caller, and that session is attributed to the agent. `requireIdentifiedCaller:
  # true` refuses such sessions; an earlier version of this installer wrote it, so remove it if present.
  if grep -q '^requireIdentifiedCaller:' "$ROUTER/upstreams.yaml"; then
    cp -p "$ROUTER/upstreams.yaml" "$ROUTER/upstreams.yaml.bak_$(date +%Y%m%d_%H%M%S)"
    grep -v '^requireIdentifiedCaller:' "$ROUTER/upstreams.yaml" > "$ROUTER/upstreams.yaml.new" \
      && mv "$ROUTER/upstreams.yaml.new" "$ROUTER/upstreams.yaml"
  fi
  chmod 600 "$ROUTER/upstreams.yaml"

  # The route engines use: the first anthropic glob, made concrete ("*-ant-aws" -> "heia-ant-aws").
  GLOB="$(awk '/^[[:space:]]*- match:/{gsub(/.*match: *"|".*/,"");m=$0} /^[[:space:]]*shape: *"anthropic"/{print m; exit}' "$ROUTER/upstreams.yaml")"
  ROUTE="${GLOB//\*/heia}"
  ROUTER_ID="$NAME|http://127.0.0.1:5100"

  # THE ROUTER'S POLICY — the base set, exactly these six rules (what the reference install runs):
  #   agent        -> *       inbound    the agent itself may open sessions
  #   agent        -> *       outbound   ...and use the models this router serves
  #   owner-email  -> agent   inbound    the owner, relayed through THIS agent only — the relay check
  #   owner-email  -> *       outbound   ("may this agent relay for this person") names the ADDRESS
  #   owner-hash   -> agent   inbound    ...and the same for the owner's subject hash, which is how the
  #   owner-hash   -> *       outbound   person is named once the session is open
  # WHY '*' FOR THE AGENT: the router checks the agent's own session envelope with the destination
  # "self", not the agent's name, so "agent -> agent" never matches; and a route rule is matched against
  # the whole "route|model" string, so "*-ant-aws" alone never matches "heia-ant-aws|zai.glm-5". Either
  # miss is refused — reported only as "agent_jwt decrypt failed: 'r' is an invalid start" (the router
  # redacts the body it refused), and every turn then dies with "no LLM route".
  # A person reaches the router as the sha512 (hex) of their lower-cased email, never the address.
  if [ "$OS" = "Darwin" ]; then OWNER_HASH="$(printf '%s' "$OWNER" | tr '[:upper:]' '[:lower:]' | shasum -a 512 | cut -d' ' -f1)"
  else OWNER_HASH="$(printf '%s' "$OWNER" | tr '[:upper:]' '[:lower:]' | sha512sum | cut -d' ' -f1)"; fi
  OWNER_LC="$(printf '%s' "$OWNER" | tr '[:upper:]' '[:lower:]')"
  WANT="$(printf '%s\n' "$NAME|*|inbound" "$NAME|*|outbound" "$OWNER_LC|$NAME|inbound" "$OWNER_LC|*|outbound" \
                        "$OWNER_HASH|$NAME|inbound" "$OWNER_HASH|*|outbound")"
  # OPENROUTER model ids carry a slash ("moonshotai/kimi-k2"), and the router's glob '*' does not cross
  # '/'. With an OpenRouter route the three outbound rules get a '*/*' twin, so those models are allowed.
  MGLOB='*'
  if grep -q '^[[:space:]]*url: *"https://openrouter\.ai' "$ROUTER/upstreams.yaml"; then
    MGLOB='*,*/*'
    WANT="$(printf '%s\n' "$WANT" "$NAME|*/*|outbound" "$OWNER_LC|*/*|outbound" "$OWNER_HASH|*/*|outbound")"
  fi
  WANT="$(printf '%s\n' "$WANT" | sort)"
  NRULES="$(printf '%s\n' "$WANT" | wc -l | tr -d ' ')"
  router_rules() {   # what the router ENFORCES — the list it prints at startup
    grep -a -o "\[policy\]   sender='[^']*' dest='[^']*' realm='[^']*' dir='[a-z]*'" "$ROUTER/router.log" 2>/dev/null \
      | sed "s/.*sender='\([^']*\)' dest='\([^']*\)' realm='[^']*' dir='\([a-z]*\)'/\1|\2|\3/" | sort
  }
  # START ORDER: router first, then the agent (the documented order — an agent started before its
  # router reports errors that have nothing to do with their cause). So the agent is stopped before
  # the router is touched and started again in step 4, once the router is up.
  if [ -f "$AGENT/$ABIN" ] && listening 8770; then
    ( cd "$AGENT" && activate stop agent > /tmp/heia-agent-stop.log 2>&1 )
    for i in $(seq 1 20); do listening 8770 || break; sleep 1; done
    note "agent stopped — the router starts first"
  fi
  router_restart() {
    spin "Starting the router"
    ( cd "$ROUTER" && activate stop router > /tmp/heia-router-stop.log 2>&1 )
    for i in $(seq 1 20); do listening 5100 || break; sleep 1; done
    ( cd "$ROUTER" && activate_bg restart router > /tmp/heia-router-start.log 2>&1 )
    wait_port 5100 60 || die "the router did not start — see $ROUTER/router.log"
    for i in $(seq 1 30); do grep -a -q "Now listening on" "$ROUTER/router.log" 2>/dev/null && break; sleep 1; done
    sleep 3
  }
  router_restart
  if [ "$(router_rules)" != "$WANT" ]; then
    # Anything else — the open wildcards of a fresh router, a looser rule, an extra one — is reset:
    # --init-policy only ADDS rules, so the old store is moved aside (kept as a backup), the router
    # starts from its fresh default, and exactly the base rules are written. Re-running this
    # installer therefore always repairs the router's permissions.
    note "Setting the router's policy (only this agent, and you through it)..."
    [ -f "$ROUTER/router-policy.he" ] && mv "$ROUTER/router-policy.he" "$ROUTER/router-policy.he.bak_$(date +%Y%m%d_%H%M%S)"
    router_restart
    # --init-policy gives every sender in one run the same "vouch" answer, so it takes two runs.
    # Answers: no external authorizer · who · models (* = every model this router serves) · vouch · write.
    #   1. the agent: vouch blank (= '*'). This first run also removes the fresh router's open wildcards.
    #   2. the owner — address AND subject hash — vouched for by this agent only (additive).
    : > /tmp/heia-router-policy.log
    # THE LICENCE CHECK can fail transiently right after the router restarts ("License verification:
    # Failed" — seen on the Mac and on WSL, each time fine on a retry). That attempt writes nothing,
    # so it is simply run again, up to 4 times, 15 s apart.
    for ANSWERS in "$(printf 'N\n%s\n%s\n\ny\n' "$NAME" "$MGLOB")" "$(printf 'N\n%s,%s\n%s\n%s\ny\n' "$OWNER_LC" "$OWNER_HASH" "$MGLOB" "$NAME")"; do
      for TRY in 1 2 3 4; do
        ( cd "$ROUTER" && set -a && . ./env-file && set +a \
          && printf '%s\n' "$ANSWERS" | "./$RBIN" --init-policy > /tmp/heia-router-policy.try 2>&1 ); RC=$?
        cat /tmp/heia-router-policy.try >> /tmp/heia-router-policy.log
        grep -q 'License verification: Failed' /tmp/heia-router-policy.try || break
        [ "$TRY" = 4 ] && die "the router's licence check kept failing — see /tmp/heia-router-policy.log"
        note "the router's licence check failed (it happens right after a restart) — retrying in 15 s"
        spin "Waiting to retry"; sleep 15; spin "Writing the router's policy"
      done
      [ "$RC" = 0 ] || die "could not write the router policy — see /tmp/heia-router-policy.log"
    done
    router_restart
  fi
  if [ "$(router_rules)" != "$WANT" ]; then
    note "The router enforces:"; router_rules | sed 's/^/    /'
    die "the router's policy is not the expected $NRULES rules — see /tmp/heia-router-policy.log"
  fi
  ok "router running on :5100 — enforcing $NRULES rules: $NAME, and $OWNER only through it"

  MODEL="$(state_get model)"
  if [ -z "$MODEL" ]; then
    # THE MODEL — a short numbered list of CHAT models. The provider also lists embedding, image,
    # video, rerank and speech models; none of them can hold a conversation, so they are left out
    # (the full list: cd ~/heia-router && hexaeight-activate models).
    spin "Asking the provider which models it has"
    ( cd "$ROUTER" && activate models ) > /tmp/heia-models.log 2>&1
    MODELS="$(grep -E '^ {6,}[a-z0-9][a-z0-9._:/-]*$' /tmp/heia-models.log | awk '{print $1}' \
      | grep -Eiv 'embed|rerank|canvas|reel|sonic|titan|stability|twelvelabs|upscale|image|vision|voxtral|pixtral|safeguard|marengo|pegasus|:[0-9]+k$' \
      | sort -u)"
    [ -n "$MODELS" ] || { spin_done; sed 's/^/    /' /tmp/heia-models.log; die "the provider listed no chat models — check the key and region"; }
    DEF="$(printf '%s\n' "$MODELS" | grep -Ex 'zai\.glm-5|glm-5' | head -1)"
    [ -n "$DEF" ] || DEF="$(printf '%s\n' "$MODELS" | grep -E 'claude-sonnet' | tail -1)"
    [ -n "$DEF" ] || DEF="$(printf '%s\n' "$MODELS" | head -1)"
    DEFN="$(printf '%s\n' "$MODELS" | grep -nxF "$DEF" | cut -d: -f1)"
    note "Which model should the agent use? (prices differ a lot between them)"
    printf '%s\n' "$MODELS" | awk '{printf "%3d. %-44s\n", NR, $0}' | pr -2 -t -w 100 | sed 's/^/  /'
    ask "Number (or a model id)" "$DEFN"
    case "$REPLY" in
      ''|*[!0-9]*) MODEL="$REPLY" ;;
      *) MODEL="$(printf '%s\n' "$MODELS" | sed -n "${REPLY}p")" ;;
    esac
    [ -n "$MODEL" ] || die "no model chosen"
    state_set model "$MODEL"
  fi
else
  ROUTER_ID="$(state_get router)"; ROUTE="$(state_get route)"; MODEL="$(state_get model)"
  [ -n "$ROUTER_ID" ] || { ask "Router — <its identity>|<its URL>   e.g. web0-quiet-amber-fern42|https://router.example.com"; ROUTER_ID="$REPLY"; state_set router "$ROUTER_ID"; }
  [ -n "$ROUTE" ]     || { ask "Route name on that router (anthropic dialect, e.g. claude-ant-aws)"; ROUTE="$REPLY"; state_set route "$ROUTE"; }
  [ -n "$MODEL" ]     || { ask "Provider model id"; MODEL="$REPLY"; state_set model "$MODEL"; }
  case "$ROUTER_ID" in *"|"http*) ;; *) die "the router must be written as <identity>|<url>";; esac
  note "That router's owner must admit $NAME (and $OWNER) in its policy, or every turn is refused."
fi
ok "engines will use route ${B}$ROUTE${N}, model ${B}$MODEL${N}"

# ══ 4 · the agent ══════════════════════════════════════════════════════════════════════════════════
step "4 · Agent"
link_licence "$AGENT"
if [ ! -f "$AGENT/$ABIN" ]; then
  spin "Downloading the agent and its runtime (a few hundred MB — a minute or two)"
  activate install-agent --dir "$AGENT" > /tmp/heia-install-agent.log 2>&1 \
    || die "install-agent failed — see /tmp/heia-install-agent.log"
  state_set agent "$(rel_top agent tag)"
  state_set engine-harness "$(rel_top engine-harness tag)"; state_set engine-mindmapchat "$(rel_top engine-mindmapchat tag)"
  ok "agent installed and verified against its published hash"
else
  # AN UPGRADE — the agent is stopped first (the router step stops it too; with a router elsewhere it
  # may still run). install-agent keeps the old binary beside the new one, and REFUSES a binary that is
  # no published release at all (a test build): that one is left alone.
  if is_current agent "$AGENT/$ABIN" agent; then
    ok "agent installed — current ($(state_get agent))"
  else
    T="$(rel_top agent tag)"
    ( cd "$AGENT" && activate stop agent > /tmp/heia-agent-stop.log 2>&1 )
    spin "Updating the agent to $T (a few hundred MB — a minute or two)"
    AF=""; [ "$OS" = "Darwin" ] && AF="--force"; [ "${FORCE_AGENT:-0}" = 1 ] && AF="--force"
    if activate install-agent --dir "$AGENT" $AF > /tmp/heia-install-agent.log 2>&1; then
      state_set agent "$T"; updated "agent → $T"; ok "agent updated to $T (the previous binary is kept beside it)"
    elif grep -q 'A DIFFERENT FILE' /tmp/heia-install-agent.log; then
      warn "the agent here is not a published release (a test build?) — left as it is. FORCE_AGENT=1 replaces it with $T."
    else
      warn "the agent was not updated — see /tmp/heia-install-agent.log; the installed one stays"
    fi
  fi
  upgrade_engine engine-harness harness hexaeight-engine
  upgrade_engine engine-mindmapchat mindmapchat hexaeight-harness
fi
if [ "$OS" = "Darwin" ]; then
  # the agent, and the engines it brought with it (~/.heia/runtime/harness, mindmapchat)
  mac_sign "$AGENT/$ABIN" "$HOME"/.heia/runtime/harness/* "$HOME"/.heia/runtime/mindmapchat/*
  mac_mask
fi

spin "Checking the sandbox"
SANDBOX="$(cd "$AGENT" && activate sandbox 2>&1)"
if ! printf '%s' "$SANDBOX" | grep -q "WORKING"; then
  spin_done; printf '%s\n' "$SANDBOX" | sed 's/^/    /'
  die "the sandbox cannot run on this machine — fix it as shown above, then re-run the installer."
fi
ok "sandbox working"
[ -f "$HOME/.claude/settings.json" ] && warn "~/.claude/settings.json exists — it can take the 'claude' engine off the router. Left untouched."

( cd "$AGENT" && activate add-policy base-default --owner "$OWNER" --no-prompt --replace-open > /tmp/heia-policy.log 2>&1 ) \
  || die "could not write the baseline policy — see /tmp/heia-policy.log"
ok "owner set and baseline policy written"

spin "Sealing the engines against the router"
activate engine --auto --dir "$AGENT" --route "$ROUTE" --model "$MODEL" --router "$ROUTER_ID" > /tmp/heia-engines.log 2>&1 \
  || die "could not seal the engines — see /tmp/heia-engines.log"
ok "$(grep -o '[0-9]* engine(s) sealed' /tmp/heia-engines.log | tail -1) against the router"

# MESSAGES FOR PEOPLE AT THIS AGENT ("incoming"): ON BY DEFAULT. Without it the agent exposes no
# /api/incoming and a person who registered their email here (workspace → Messages → "Receive my messages
# here") still gets nothing. Whether a message is ACCEPTED is still the agent's policy: the sender's agent
# must be admitted, and the sending person must be allowed to reach the recipient. Set in the config
# before the agent starts, so no extra restart. ENABLE_INCOMING=0 leaves it off.
if [ "${ENABLE_INCOMING:-1}" = 1 ]; then
  INODE="$HOME/.heia/runtime/node/bin/node"; [ -x "$INODE" ] || INODE="$(command -v node || true)"
  ICFG="$AGENT/hexaeight-agent.json"
  if [ -n "$INODE" ] && ! "$INODE" -e 'const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
                                       process.exit(d.incoming === true ? 0 : 1)' "$ICFG" 2>/dev/null; then
    cp -p "$ICFG" "$ICFG.bak_$(date +%Y%m%d_%H%M%S)"
    "$INODE" -e '
      const fs = require("fs"), p = process.argv[1];
      const d = JSON.parse(fs.readFileSync(p, "utf8"));
      d.incoming = true;
      fs.writeFileSync(p, JSON.stringify(d, null, 2) + "\n");' "$ICFG" || die "could not update $ICFG"
  fi
  ok "messages for people at this agent: on (register in workspace → Messages)"
fi

# MACHINES (the agent's "fleet"): lets you, the owner, work on THIS computer from chat (workspace →
# Machines) — every command the model proposes is held until you approve it. Owner only. Enabled in
# the config before the agent starts (so no extra restart), and this computer is added as a machine
# that runs commands directly (--local, no SSH). Edited with the agent's own Node runtime (no python).
# ON BY DEFAULT (2026-09-29). ENABLE_FLEET=0 skips this step. (It was off for a while when a tunnel
# failure was blamed on it — the cause was Cloudflare refusing new quick tunnels, not Machines.)
ENABLE_FLEET="${ENABLE_FLEET:-1}"
if [ "$ENABLE_FLEET" = 1 ]; then
NODE="$HOME/.heia/runtime/node/bin/node"; [ -x "$NODE" ] || NODE="$(command -v node || true)"
CFG="$AGENT/hexaeight-agent.json"
# Read as JSON, not grepped: the config spreads "fleet": { "enabled": true } over several lines.
fleet_on() { "$NODE" -e 'const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
                        process.exit(d.fleet && d.fleet.enabled === true ? 0 : 1)' "$CFG" 2>/dev/null; }
if [ -n "$NODE" ] && ! fleet_on; then
  cp -p "$CFG" "$CFG.bak_$(date +%Y%m%d_%H%M%S)"
  "$NODE" -e '
    const fs = require("fs"), p = process.argv[1];
    const d = JSON.parse(fs.readFileSync(p, "utf8"));
    d.fleet = Object.assign({}, d.fleet, { enabled: true });
    fs.writeFileSync(p, JSON.stringify(d, null, 2) + "\n");' "$CFG" || die "could not update $CFG"
fi
MACHINE="$(hostname -s 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-\n' '-')"; MACHINE="${MACHINE:-this-machine}"
if [ "$(state_get fleet_local)" != "$MACHINE" ]; then
  spin "Adding this computer to Machines"
  # The agent reads its identity from env-file in its folder, as when it starts. Its licence check can
  # fail transiently (like the router's), so a failure is retried.
  for TRY in 1 2 3; do
    ( cd "$AGENT" && set -a && . ./env-file && set +a \
      && "./$ABIN" hexaeight-agent.json fleet-host add --name "$MACHINE" --host localhost --user "$(id -un)" --local \
         < /dev/null > /tmp/heia-fleet.log 2>&1 ) && { state_set fleet_local "$MACHINE"; break; }
    sleep 10
  done
fi
if [ "$(state_get fleet_local)" = "$MACHINE" ]; then ok "Machines on — this computer is '$MACHINE' (workspace → Machines; you approve every command)"
else warn "Machines could not add this computer — see /tmp/heia-fleet.log (the rest of the install is unaffected)"; fi
fi

agent_start "Starting the agent" || die "the agent did not start — see $AGENT/agent.log"
ok "agent running on :8770"

# ══ 5 · the workspace ══════════════════════════════════════════════════════════════════════════════
step "5 · Workspace"
WST="$(rel_top workspace tag)"
if [ ! -f "$HOME/.heia/runtime/workspace/index.html" ]; then
  spin "Installing the workspace"
  ( cd "$AGENT" && activate install-workspace > /tmp/heia-install-workspace.log 2>&1 ) \
    || die "install-workspace failed — see /tmp/heia-install-workspace.log"
  [ -n "$WST" ] && state_set workspace "$WST"
elif [ -n "$WST" ] && [ "$(state_get workspace)" != "$WST" ]; then
  # The workspace folder carries no version, so what this installer recorded is the only record — none
  # (an install by an earlier version of this script) means it is fetched once and then recorded.
  # install-workspace --force backs up config.js and writes it again for this agent.
  spin "Updating the workspace to $WST"
  WA=""; [ "$SKIP_GATEWAY" = 1 ] || WA="--agent $NAME"
  if ( cd "$AGENT" && activate install-workspace --force $WA > /tmp/heia-install-workspace.log 2>&1 ); then
    state_set workspace "$WST"; updated "workspace → $WST"; ok "workspace updated to $WST"
    WSPID0="$(if [ "$OS" = "Darwin" ]; then lsof -tiTCP:5620 -sTCP:LISTEN 2>/dev/null | head -1
              else ss -ltnp 2>/dev/null | grep ':5620 ' | grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2; fi)"
    [ -n "$WSPID0" ] && kill "$WSPID0" 2>/dev/null && sleep 1   # its server restarts below on the new files
  else
    warn "the workspace was not updated — see /tmp/heia-install-workspace.log; the installed one stays"
  fi
else
  spin "Checking the workspace"
  ( cd "$AGENT" && activate install-workspace > /tmp/heia-install-workspace.log 2>&1 ) \
    || die "install-workspace failed — see /tmp/heia-install-workspace.log"
fi
# The workspace is static files plus a small static server — `restart workspace` only says so and
# starts nothing. Start that server here, detached, so it outlives this script; autostart (below)
# brings it back at the next login.
WS="$HOME/.heia/runtime/workspace"; NODE="$HOME/.heia/runtime/node/bin/node"
[ -x "$NODE" ] || NODE="$(command -v node || true)"
[ -f "$WS/serve.mjs" ] && [ -n "$NODE" ] || die "the workspace or its node runtime is missing — see /tmp/heia-install-workspace.log"
if ! listening 5620; then
  if command -v setsid >/dev/null; then
    ( cd "$WS" && setsid "$NODE" serve.mjs --port 5620 --host 127.0.0.1 > "$HOME/.heia/workspace-5620.log" 2>&1 < /dev/null & )
  else
    ( cd "$WS" && nohup "$NODE" serve.mjs --port 5620 --host 127.0.0.1 > "$HOME/.heia/workspace-5620.log" 2>&1 < /dev/null & )
  fi
fi
spin "Starting the workspace"
wait_port 5620 30 || die "the workspace did not start — see ~/.heia/workspace-5620.log"
ok "workspace on http://localhost:5620"


# ══ 6 · the gateway — reachable from anywhere (skip with --skip-gateway) ═══════════════════════════
# Two tunnels, both cloudflared, both HTTPS:
#   the AGENT publishes itself — "reach": cloudflared + "register": true. It starts its own tunnel,
#     registers that URL under its name, and re-registers after every restart. Other agents, and
#     your workspace, find it BY NAME. The tunnel only ever carries end-to-end encrypted messages.
#   the WORKSPACE gets a tunnel in front of :5620, because browser sign-in needs HTTPS (WebCrypto).
#     It is then pointed at the agent by name instead of localhost.
WS_URL=""; AGENT_URL=""
if [ "$SKIP_GATEWAY" = 1 ]; then
  step "6 · Gateway — skipped (--skip-gateway): this install is reachable on this machine only"
else
  step "6 · Gateway (reachable from anywhere)"
  CF="$HOME/.heia/bin/cloudflared"
  if [ ! -x "$CF" ]; then
    mkdir -p "$HOME/.heia/bin"
    spin "Downloading cloudflared (Cloudflare's tunnel client) into ~/.heia/bin"
    if [ "$OS" = "Darwin" ]; then
      CFT="$(mktemp -d -t heia-cf)"
      curl -fsSL -o "$CFT/cf.tgz" https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-arm64.tgz \
        && tar -xzf "$CFT/cf.tgz" -C "$CFT" || die "could not download cloudflared"
      CFX="$(find "$CFT" -type f -name cloudflared | head -1)"
      [ -n "$CFX" ] && mv "$CFX" "$CF" || die "cloudflared was not in the download"
    else
      curl -fsSL -o "$CF" https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
        || die "could not download cloudflared"
    fi
    chmod +x "$CF"
  fi
  [ "$OS" = "Darwin" ] && mac_sign "$CF"
  "$CF" --version >/dev/null 2>&1 || die "cloudflared does not run — see: $CF --version"
  ok "$("$CF" --version 2>/dev/null | head -1)"

  # THE FALLBACK: frpc, for the fastagents.net relay the agent uses when Cloudflare gives it no address
  # (its account-less tunnels are rate-limited per public IP). Downloaded now so the fallback is there
  # when it is needed; the agent starts it itself, with a ticket only it can get from the registry.
  FRPC="$HOME/.heia/bin/frpc"; FRPV=0.71.0
  if [ ! -x "$FRPC" ]; then
    spin "Downloading frpc (the fastagents.net relay client) into ~/.heia/bin"
    if [ "$OS" = "Darwin" ]; then FRPA="darwin_arm64"; else FRPA="linux_amd64"; fi
    FRT="$(mktemp -d)"
    if curl -fsSL -o "$FRT/frp.tgz" "https://github.com/fatedier/frp/releases/download/v$FRPV/frp_${FRPV}_${FRPA}.tar.gz" \
       && tar -xzf "$FRT/frp.tgz" -C "$FRT" --strip-components=1 "frp_${FRPV}_${FRPA}/frpc"; then
      mv "$FRT/frpc" "$FRPC" && chmod +x "$FRPC"
      [ "$OS" = "Darwin" ] && mac_sign "$FRPC"
    else warn "could not download frpc — the relay fallback will not be available (Cloudflare still is)"; fi
  fi

  # THE AGENT: publish itself — Cloudflare first, the fastagents.net relay if Cloudflare gives no address,
  # and its workspace (:5620) with it on the relay. Edited with the agent's own Node runtime (no python).
  CFG="$AGENT/hexaeight-agent.json"
  if ! grep -q '"mode": *"cloudflared"' "$CFG" || ! grep -q '"register": *true' "$CFG" || ! grep -q '"workspacePort"' "$CFG"; then
    cp -p "$CFG" "$CFG.bak_$(date +%Y%m%d_%H%M%S)"
    "$NODE" -e '
      const fs = require("fs"), [p, bin] = process.argv.slice(1);
      const d = JSON.parse(fs.readFileSync(p, "utf8"));
      d.reach = Object.assign({}, d.reach, { mode: "cloudflared", bin, fallback: "fastagents", workspacePort: 5620 });
      d.register = true;
      fs.writeFileSync(p, JSON.stringify(d, null, 2) + "\n");' "$CFG" "$CF" || die "could not update $CFG"
    agent_start "Restarting the agent so it publishes itself" || die "the agent did not come back — see $AGENT/agent.log"
  fi
  spin "Waiting for the agent's public address"
  AGENT_WS=""
  for i in $(seq 1 60); do
    LINE="$(grep -a '^\[reach\] mode=.*tunnel up' "$AGENT/agent.log" 2>/dev/null | tail -1)"
    AGENT_URL="$(printf '%s' "$LINE" | grep -o 'tunnel up *https://[^ ]*' | grep -o 'https://.*')"
    AGENT_WS="$(printf '%s' "$LINE" | grep -o 'workspace https://[^ ]*' | grep -o 'https://.*')"
    [ -n "$AGENT_URL" ] && break
    # stop waiting once the agent has given up (its last word on reach, frpc chatter aside)
    grep -a '^\[reach\]' "$AGENT/agent.log" 2>/dev/null | grep -v '^\[reach\] frpc:' | tail -1 | grep -q 'publishing nothing' && break
    sleep 2
  done
  [ -n "$AGENT_URL" ] || die "the agent's tunnel did not come up — see the [reach] lines in $AGENT/agent.log"
  case "$AGENT_URL" in *fastagents.net*) ok "agent reachable at $AGENT_URL  (fastagents.net relay — Cloudflare gave no address)";;
                       *) ok "agent reachable at $AGENT_URL";; esac
  REG=""
  for i in $(seq 1 20); do REG="$(grep -a '\[register\]' "$AGENT/agent.log" | tail -1)"; [ -n "$REG" ] && break; sleep 2; done
  case "$REG" in *OK*) ok "registered as $NAME — other agents find it by name";;
                 *) warn "registration not confirmed yet (it retries): ${REG:-no [register] line yet}";; esac

  # THE WORKSPACE: find the agent by name, served over HTTPS.
  spin "Pointing the workspace at $NAME"
  ( cd "$AGENT" && activate install-workspace --agent "$NAME" > /tmp/heia-install-workspace-agent.log 2>&1 ) \
    || die "could not point the workspace at $NAME — see /tmp/heia-install-workspace-agent.log"
  WSLOG="$HOME/.heia/workspace-tunnel.log"
  if [ -n "$AGENT_WS" ]; then
    # On the relay the agent already carries its workspace: no second tunnel, nothing more asked of Cloudflare.
    WS_URL="$AGENT_WS"
  else
  # ONE workspace tunnel. A running one is reused (its address is in its log); matched on the --url
  # argument itself, since the command line carries other flags in between.
  if ! ps -eo args 2>/dev/null | grep -v grep | grep -q -- "--url http://127.0.0.1:5620"; then
    : > "$WSLOG"
    if command -v setsid >/dev/null; then
      ( setsid "$CF" tunnel --no-autoupdate --url http://127.0.0.1:5620 > "$WSLOG" 2>&1 < /dev/null & )
    else
      ( nohup "$CF" tunnel --no-autoupdate --url http://127.0.0.1:5620 > "$WSLOG" 2>&1 < /dev/null & )
    fi
  fi
  spin "Opening the workspace's public address"
  for i in $(seq 1 45); do
    WS_URL="$(grep -a -o 'https://[a-z0-9-]*\.trycloudflare\.com' "$WSLOG" 2>/dev/null | tail -1)"
    [ -n "$WS_URL" ] && break; sleep 2
  done
  [ -n "$WS_URL" ] || die "the workspace tunnel did not come up — see $WSLOG"
  fi
  # A new tunnel address can take a minute to answer. Hand it out only once it does.
  spin "Waiting for $WS_URL to answer (about a minute)"
  for i in $(seq 1 45); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$WS_URL/")" = "200" ] && break; sleep 3
  done
  ok "workspace reachable at $WS_URL"
fi

# THE heia COMMAND — restart, start, stop, status and logs for this machine's services, from any folder,
# always through whoever owns them (systemd / launchd / Activate). Written from this installer (a
# `curl | bash` run has no files beside it), into ~/.heia/bin, which the shell profile puts on PATH.
mkdir -p "$HOME/.heia/bin"
cat > "$HOME/.heia/bin/heia" <<'HEIA_EOF'
#!/bin/bash
# heia — this machine's HexaEight services: restart, start, stop, status, logs. Works from any folder.
#
#   heia restart [agent|router|workspace|all]   (default: agent; "router" restarts the agent after it)
#   heia start   [agent|router|workspace|all]
#   heia stop    [agent|router|workspace|all]
#   heia status
#   heia logs    [agent|router|workspace]       (follows; Ctrl-C to leave)
#
# ONE OWNER PER SERVICE. After install, the service manager runs router, agent and workspace —
# systemd --user on Linux/WSL, launchd on macOS — and brings them back when they stop. Everything here
# goes THROUGH that manager: a copy started beside it fights it for the port, and the manager then
# restarts the loser forever. Where there is no manager, Activate does it, from the service's own folder
# and in its own session, so what it starts is not killed with this terminal.
set -u
export DOTNET_ROOT="$HOME/.dotnet"
export PATH="$HOME/.dotnet:$HOME/.dotnet/tools:$HOME/.heia/bin:$PATH"
ROUTER="$HOME/heia-router"; AGENT="$HOME/heia-agent"; STATE="$HOME/.heia/install.state"
WS="$HOME/.heia/runtime/workspace"; NODE="$HOME/.heia/runtime/node/bin/node"
OS="$(uname -s)"
if [ -t 1 ]; then B=$'\e[1m'; G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; N=$'\e[0m'; else B= G= R= Y= N=; fi

listening() {
  if [ "$OS" = "Darwin" ]; then lsof -nP -iTCP:"$1" -sTCP:LISTEN > /dev/null 2>&1
  else ss -ltn 2>/dev/null | grep -q ":$1 "; fi
}
port_pid() {
  if [ "$OS" = "Darwin" ]; then lsof -tiTCP:"$1" -sTCP:LISTEN 2>/dev/null | head -1
  else ss -ltnp 2>/dev/null | grep ":$1 " | grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2; fi
}
port_of() { case "$1" in router) echo 5100;; agent) echo 8770;; workspace) echo 5620;; esac; }

# Who owns the services here?
MANAGER=none
UL="$HOME/.config/systemd/user"; UM="$HOME/Library/LaunchAgents"
if [ "$OS" = "Darwin" ]; then
  ls "$UM"/com.hexaeight.*.plist > /dev/null 2>&1 && MANAGER=launchd
elif command -v systemctl > /dev/null 2>&1 && ls "$UL"/hexaeight-*.service > /dev/null 2>&1 \
     && systemctl --user show-environment > /dev/null 2>&1; then
  MANAGER=systemd
fi

# Is this service installed here at all? (A machine that uses a router elsewhere has no router.)
installed() {
  case "$MANAGER" in
    systemd) [ -f "$UL/hexaeight-$1.service" ] ;;
    launchd) [ -f "$UM/com.hexaeight.$1.plist" ] ;;
    *) case "$1" in router) [ -d "$ROUTER" ] ;; agent) [ -d "$AGENT" ] ;; workspace) [ -f "$WS/serve.mjs" ] ;; esac ;;
  esac
}

wait_up() {   # wait_up <service> <seconds>
  local p i=0; p="$(port_of "$1")"
  printf '  %-10s ' "$1"
  while [ "$i" -lt "$2" ]; do
    listening "$p" && { printf '%sup%s  (:%s)\n' "$G" "$N" "$p"; return 0; }
    printf '.'; sleep 2; i=$((i + 2))
  done
  printf ' %snot up after %ss%s — see: heia logs %s\n' "$R" "$2" "$N" "$1"; return 1
}
wait_down() { local p i=0; p="$(port_of "$1")"; while [ "$i" -lt 30 ] && listening "$p"; do sleep 1; i=$((i + 1)); done; }

# The workspace is a small static server; with no manager it is started and stopped directly.
ws_direct() {
  case "$1" in
    stop)  local pid; pid="$(port_pid 5620)"; [ -n "$pid" ] && kill "$pid" 2> /dev/null; wait_down workspace ;;
    *)     [ "$1" = restart ] && ws_direct stop
           listening 5620 && return 0
           if command -v setsid > /dev/null 2>&1; then ( cd "$WS" && setsid "$NODE" serve.mjs --port 5620 --host 127.0.0.1 > "$HOME/.heia/workspace-5620.log" 2>&1 < /dev/null & )
           else ( cd "$WS" && nohup "$NODE" serve.mjs --port 5620 --host 127.0.0.1 > "$HOME/.heia/workspace-5620.log" 2>&1 < /dev/null & ); fi ;;
  esac
}

act() {   # act start|stop|restart <service>
  local verb="$1" s="$2"
  case "$MANAGER" in
    systemd) systemctl --user "$verb" "hexaeight-$s.service" ;;
    launchd)
      local label="com.hexaeight.$s" plist="$UM/com.hexaeight.$s.plist" dom="gui/$(id -u)"
      case "$verb" in
        stop)    launchctl bootout "$dom/$label" 2> /dev/null || launchctl unload "$plist" 2> /dev/null ;;
        start)   launchctl bootstrap "$dom" "$plist" 2> /dev/null || launchctl load "$plist" 2> /dev/null
                 launchctl kickstart "$dom/$label" 2> /dev/null ;;
        restart) launchctl kickstart -k "$dom/$label" 2> /dev/null \
                   || { launchctl unload "$plist" 2> /dev/null; launchctl load "$plist" 2> /dev/null; } ;;
      esac ;;
    *)
      if [ "$s" = workspace ]; then ws_direct "$verb"; return; fi
      local dir="$AGENT"; [ "$s" = router ] && dir="$ROUTER"
      local v="$verb"; [ "$v" = start ] && v=restart     # Activate starts by restarting
      if command -v setsid > /dev/null 2>&1; then ( cd "$dir" && setsid -w hexaeight-activate "$v" "$s" < /dev/null > "/tmp/heia-$v-$s.log" 2>&1 )
      else ( cd "$dir" && nohup hexaeight-activate "$v" "$s" < /dev/null > "/tmp/heia-$v-$s.log" 2>&1 ); fi ;;
  esac
}

limit() { local s; for s in "$@"; do installed "$s" && printf '%s ' "$s"; done; }
targets() {   # in start order
  case "${1:-agent}" in
    all)       limit router agent workspace ;;
    router)    limit router agent ;;          # the agent follows its router
    agent)     limit agent ;;
    workspace) limit workspace ;;
    *) echo "unknown service '$1' — agent, router, workspace or all" >&2; exit 2 ;;
  esac
}
reverse() { local out="" s; for s in "$@"; do out="$s $out"; done; printf '%s' "$out"; }
timeout_of() { case "$1" in agent) echo 180;; router) echo 90;; *) echo 60;; esac; }   # the agent opens its port only after it has a public address

name() { [ -f "$STATE" ] && sed -n 's/^identity=//p' "$STATE" | tail -1; }
public_url() {
  local n; n="$(name)"; [ -n "$n" ] || return 0
  curl -s --max-time 6 "https://registry.fastagents.net/api/resolve?name=$n" 2> /dev/null | grep -o '"url":"[^"]*"' | cut -d'"' -f4
}
# The workspace's public address: the installer's own tunnel in front of :5620 while it runs; else, with
# the agent on the fastagents.net relay, the relay carries it as <agent label>-ws.fastagents.net.
workspace_url() {
  local u="" a
  if ps -eo args 2> /dev/null | grep -v grep | grep -q -- "--url http://127.0.0.1:5620"; then
    u="$(grep -a -o 'https://[a-z0-9-]*\.trycloudflare\.com' "$HOME/.heia/workspace-tunnel.log" 2> /dev/null | tail -1)"
  fi
  if [ -z "$u" ]; then
    a="${1:-}"
    case "$a" in https://*.fastagents.net) u="${a%%.fastagents.net*}-ws.fastagents.net" ;; esac
  fi
  printf '%s' "$u"
}
answers() { [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$1")" = "200" ]; }
show_urls() {
  local a w
  a="$(public_url)"
  if [ -n "$a" ]; then
    if answers "$a/api/agentinfo"; then echo "  agent      $a  (as $(name))"
    else echo "  agent      $a  (as $(name)) ${Y}— not answering yet${N}"; fi
  fi
  w="$(workspace_url "$a")"
  if [ -n "$w" ]; then
    if answers "$w/"; then echo "  ${B}workspace  $w${N}  ← open this, sign in as the owner"
    else echo "  workspace  $w ${Y}— not answering (tunnel down? run the installer again for a new one)${N}"; fi
  elif installed workspace; then
    echo "  workspace  http://localhost:5620  (no public address — run the installer to get one)"
  fi
}

cmd="${1:-status}"; svc="${2:-}"
case "$cmd" in
  restart|start)
    list="$(targets "${svc:-agent}")"
    [ -n "$list" ] || { echo "  nothing to $cmd here"; exit 0; }
    echo "  ${B}$cmd${N} ($MANAGER): $list"
    rc=0; first="${list%% *}"
    for s in $list; do
      # systemd: the agent requires the router and the workspace the agent, so restarting the router
      # restarts both of them already — acting on them again would restart them twice.
      if [ "$MANAGER" = systemd ] && [ "$cmd" = restart ] && [ "$first" = router ] && [ "$s" != router ]; then :
      else act "$cmd" "$s"; fi
      wait_up "$s" "$(timeout_of "$s")" || rc=1
    done
    if printf '%s' "$list" | grep -q agent; then sleep 3; echo; show_urls; fi
    exit $rc ;;
  stop)
    list="$(targets "${svc:-agent}")"
    echo "  ${B}stop${N} ($MANAGER): $(reverse $list)"
    [ "$MANAGER" = none ] || [ -z "$svc" ] || [ "$svc" = all ] \
      || echo "  ${Y}note:${N} $MANAGER starts it again at the next login (use 'heia start' to bring it back now)"
    for s in $(reverse $list); do act stop "$s"; wait_down "$s"; printf '  %-10s stopped\n' "$s"; done ;;
  status)
    echo "  ${B}HexaEight on this machine${N}  (managed by: $MANAGER)"
    for s in router agent workspace; do
      installed "$s" || continue
      p="$(port_of "$s")"; st="${R}down${N}"; listening "$p" && st="${G}up${N}"
      extra=""
      [ "$MANAGER" = systemd ] && extra="  systemd: $(systemctl --user is-active "hexaeight-$s.service" 2> /dev/null)"
      printf '  %-10s %s  (:%s)%s\n' "$s" "$st" "$p" "$extra"
    done
    echo; show_urls ;;
  logs)
    s="${svc:-agent}"
    case "$MANAGER" in
      systemd) exec journalctl --user -u "hexaeight-$s.service" -n 100 -f ;;
      launchd) exec tail -n 100 -f "$HOME/.heia/logs/$s.log" ;;
      *) case "$s" in
           agent)     exec tail -n 100 -f "$AGENT/agent.log" ;;
           router)    exec tail -n 100 -f "$ROUTER/router.log" ;;
           workspace) exec tail -n 100 -f "$HOME/.heia/workspace-5620.log" ;;
         esac ;;
    esac ;;
  -h|--help|help)
    sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//' ;;
  *)
    echo "usage: heia restart|start|stop [agent|router|workspace|all] · heia status · heia logs [agent|router|workspace]" >&2
    exit 2 ;;
esac
HEIA_EOF
chmod +x "$HOME/.heia/bin/heia"
for prof in $PROFILES; do
  if ! grep -q "# >>> hexaeight-bin >>>" "$prof" 2>/dev/null; then
    printf '\n# >>> hexaeight-bin >>>  (the heia command)\nexport PATH="$HOME/.heia/bin:$PATH"\n# <<< hexaeight-bin <<<\n' >> "$prof"
  fi
done

# ══ 7 · hand over to the service manager — it starts them at login and restarts them ═══════════════
# Only now, when everything works, and with ONE owner: this installer's copies stop, then the manager
# starts its own (router, then agent once :5100 answers, then the workspace once :8770 does). Where
# there is no service manager to hand to (WSL without systemd), this installer's copies keep running.
step "7 · Start at login"
port_pid() { if [ "$OS" = "Darwin" ]; then lsof -tiTCP:"$1" -sTCP:LISTEN 2>/dev/null | head -1
             else ss -ltnp 2>/dev/null | grep ":$1 " | grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2; fi; }
start_ourselves() {   # the fallback: our own detached copies, as during the install
  if [ "$MODE" = own ] && ! listening 5100; then ( cd "$ROUTER" && activate_bg restart router > /tmp/heia-router-start.log 2>&1 ); wait_port 5100 60; fi
  listening 8770 || agent_start "Starting the agent"
  if ! listening 5620; then
    if command -v setsid > /dev/null; then ( cd "$WS" && setsid "$NODE" serve.mjs --port 5620 --host 127.0.0.1 > "$HOME/.heia/workspace-5620.log" 2>&1 < /dev/null & )
    else ( cd "$WS" && nohup "$NODE" serve.mjs --port 5620 --host 127.0.0.1 > "$HOME/.heia/workspace-5620.log" 2>&1 < /dev/null & ); fi
    wait_port 5620 30
  fi
}
MANAGER=""
if [ "$OS" = "Darwin" ]; then MANAGER=launchd
elif command -v systemctl > /dev/null 2>&1 && systemctl --user show-environment > /dev/null 2>&1; then MANAGER=systemd; fi
if [ -z "$MANAGER" ]; then
  warn "no service manager here (WSL without systemd) — the services keep running, but will not start at login"
else
  spin "Handing router, agent and workspace to $MANAGER"
  ( cd "$AGENT" && activate stop agent > /tmp/heia-agent-stop.log 2>&1 )
  [ "$MODE" = own ] && ( cd "$ROUTER" && activate stop router > /tmp/heia-router-stop.log 2>&1 )
  WSPID="$(port_pid 5620)"; [ -n "$WSPID" ] && kill "$WSPID" 2>/dev/null
  for i in $(seq 1 30); do listening 8770 || listening 5620 || { [ "$MODE" = own ] && listening 5100; } || break; sleep 1; done
  # ROUTER FIRST, AND READY. systemd's After=/Requires= only order the START: the agent is launched the
  # moment the router's process is, while the router is still checking its licence — and the agent
  # validates its routes once, at start. This drop-in holds every agent start (this hand-over, a restart,
  # a reboot) until the router answers on :5100 (up to 90 s), then 3 s more to settle — as the install itself does. (launchd needs none: Activate's agent job
  # already waits for :5100.) Written before the units are loaded, so the first start honours it too.
  if [ "$MANAGER" = systemd ] && [ "$MODE" = own ]; then
    mkdir -p "$UNITS_L/hexaeight-agent.service.d"
    cat > "$UNITS_L/hexaeight-agent.service.d/wait-for-router.conf" <<'UNIT_EOF'
# Written by the HexaEight installer: start the agent only once the router answers on :5100.
[Service]
ExecStartPre=/bin/bash -c 'for i in $(seq 1 90); do (exec 3<>/dev/tcp/127.0.0.1/5100) 2>/dev/null && { sleep 3; exit 0; }; sleep 1; done; echo "router not answering on :5100 after 90 s — starting the agent anyway"; exit 0'
TimeoutStartSec=180
UNIT_EOF
  fi
  if [ "$MODE" = own ]; then ( cd "$AGENT" && activate autostart on --agent "$AGENT" --router "$ROUTER" > /tmp/heia-autostart.log 2>&1 )
  else                     ( cd "$AGENT" && activate autostart on --agent "$AGENT" > /tmp/heia-autostart.log 2>&1 ); fi
  UP=1
  { [ "$MODE" != own ] || wait_port 5100 90; } && wait_port 8770 150 && wait_port 5620 90 || UP=0
  if [ "$UP" = 1 ]; then
    ok "$MANAGER runs them now — they start at login and come back if they stop"
  else
    warn "$MANAGER did not bring everything up (see /tmp/heia-autostart.log) — starting them directly instead"
    start_ourselves
  fi
  # ONE MORE, CALM RESTART OF THE AGENT. After an install, the agent that came up at the end has more
  # than once been unable to open its own sealed files (the workspace then shows InvalidOperationException
  # — terms, sign-in); one restart a little later has fixed it every time (seen three times on WSL,
  # 2026-09-29). Likely the several quick agent starts an install makes; until that is pinned down, the
  # installer does what fixed it by hand: let things settle, restart the agent once, through its owner.
  spin "Letting it settle, then restarting the agent once"
  sleep 20
  case "$MANAGER" in
    systemd) systemctl --user restart hexaeight-agent.service > /dev/null 2>&1 ;;
    launchd) launchctl kickstart -k "gui/$(id -u)/com.hexaeight.agent" > /dev/null 2>&1 ;;
  esac
  sleep 3
  if wait_port 8770 180 && { listening 5620 || wait_port 5620 60; }; then ok "agent restarted cleanly"
  else warn "the agent did not answer after the final restart — run: heia restart"; fi
  # The agent started again, so it published itself again: take its address from the registry.
  if [ -n "$AGENT_URL" ]; then
    spin "Waiting for the agent to publish itself again"
    for i in $(seq 1 45); do
      U="$(curl -s --max-time 5 "https://registry.fastagents.net/api/resolve?name=$NAME" | grep -o '"url":"[^"]*"' | cut -d'"' -f4)"
      [ -n "$U" ] && [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$U/api/agentinfo")" = "200" ] && { AGENT_URL="$U"; break; }
      sleep 3
    done
    ok "agent reachable at $AGENT_URL"
  fi
fi

spin_done
if [ -n "$UPDATES" ]; then printf '\n  %sUpdated this run%s (only what had a newer release):\n%s' "$B" "$N" "$UPDATES"
elif [ "$RERUN" = 1 ] && [ -n "$REL" ]; then printf '\n  Everything was already on its current release — nothing downloaded.\n'
elif [ "$RERUN" = 1 ]; then printf '\n  %s!%s The release list could not be read, so nothing was checked for updates.\n' "$Y" "$N"; fi
OPEN="${WS_URL:-http://localhost:5620}"
cat <<EOF

  ${G}${B}Done.${N}  Open ${B}$OPEN${N} and sign in as ${B}$OWNER${N} with your Authenticator.
  Ask it something — an answer in the browser proves the whole chain.

  Folders:  ~/hbia-agent   the licence — never move or rename it
            ~/heia-router  the router (your provider key is in upstreams.yaml)
            ~/heia-agent   the agent
  Manage:   ${B}heia status${N} · ${B}heia restart${N} [agent|router|all] · ${B}heia logs${N} [agent|router]
            (from any folder, in a new terminal — or after: source ${RCFILE})
EOF
[ -n "$MANAGER" ] && cat <<EOF
            Not 'hexaeight-activate restart': ${MANAGER} runs the services now, and a second copy
            started beside it fights it for the port.
EOF
if [ -n "$WS_URL" ]; then cat <<EOF

  Public:   workspace  $WS_URL
            agent      $AGENT_URL   (registered as $NAME)
  These are quick-tunnel addresses: they change when the machine restarts. The agent re-publishes
  its new one by itself; for the workspace, run this installer again to get the new link. For a
  fixed address on your own domain, use a named Cloudflare tunnel.
EOF
fi
echo
