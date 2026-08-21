# Cutting an HBIA release

The order below is not arbitrary. Each step produces something the next one needs, and two of them
depend on a human decision that cannot be automated. Skipping ahead produces builds the platform
refuses, with symptoms that look like anything except the real cause.

Budget an afternoon the first time.

---

## What identifies a build, and why there are two hashes

**SHA-256 of the downloaded file** — did it arrive intact? For users, before running anything.

**PROTECTION HASH (SHA-512)** — which build is this, as attested on the wire? This is what a peer's
approved-build gate matches on. It is the hash of the **extracted entry dll**, not of the file that
was downloaded: a self-extracting single-file build attests what it loads, not its wrapper.

Confusing the two is the most common mistake here. The download hash never appears in an allowlist.

---

## Step 0 — Decide what changed

| changed | consequences |
|---|---|
| Agent source only | new PROTECTION HASH per RID; new `ApprovedBuilds` list version; new `HexaEight.Activate` |
| Bridge / ASK / JWT | all of the above **plus** a full MVID capture and platform deploy |
| `RuntimeFrameworkVersion` | same as a library change — every registered row is invalidated |

That last row surprises people. The platform validates an IL hash computed per
*(assembly, runtime, OS)*, so the bundled .NET patch level is part of the build's identity.

---

## Step 1 — Publish the libraries (only if they changed)

Bump the version, `dotnet pack`, and **verify the packed assembly version before publishing**:

```powershell
Expand-Archive HexaEight.Bridge.<v>.nupkg -DestinationPath x
Get-ChildItem x\lib -Recurse -Filter HexaEight.Bridge.dll | ForEach-Object {
  [System.Reflection.AssemblyName]::GetAssemblyName($_.FullName).Version }
```

All TFMs must report the version you just set. An obfuscated dll newer than its sources makes MSBuild
skip the recompile, and the package silently ships the *previous* assembly — this has happened, and
it is invisible until the MVID rows fail to match.

Publish to nuget.org and wait for indexing. `dotnet restore --no-cache`; the local cache will
otherwise hand you the old package.

---

## Step 2 — MVID capture (only if libraries changed)

The platform accepts a call only when the calling assembly's `(MVID, IL-hash)` is registered in
`assemblyintegrity.txt`. Unregistered, it returns a decoy and `FetchInternalKeyAsync` fails — so a
brand-new library is refused until this is done.

**MVID is deterministic per build; the IL hash is per (assembly, runtime, OS).** So one MVID per TFM,
but a separate hash for every runtime and platform combination you ship.

Point `MvidTest` at the new version, restore `--no-cache`, and run **from an identity folder** —
`env-file` and `hexaeight.mac` are read from the working directory.

### Shared-runtime rows — for the dotnet tool and for customers building their own apps

```powershell
cd <identity-folder>
dotnet run --project <mvid-test> -c Debug -f net8.0    # then net9.0, net10.0
```

Collect the `ASK-ROW`, `JWT-ROW` and `BRIDGE-ROW` lines. **All three libraries, all three TFMs.**
MvidTest computes them locally with the validator's own algorithm, so they are valid even when the
platform call fails — which it will, first time round, because nothing is registered yet.

Repeat on **every OS you ship**: Windows, Linux (WSL is fine), macOS. Same MVIDs, different hashes.
Identical MVIDs with different IL hashes is the correct signature, not a mistake.

### Self-contained rows — for the shipped agent

The agent bundles its own runtime, so its hashes differ from the shared-runtime ones above. Publish
the harness self-contained for the target RID, run it there, and capture those rows too:

```powershell
dotnet publish <mvid-test> -c Debug -f net8.0 -r <rid> --self-contained true -o out
```

**Miss this and the agent is refused while its libraries verify clean against nuget.org** — a state
that looks exactly like tampering and is not. Cost when we skipped it: about an hour of chasing a
JSON parse error that had nothing to do with the cause.

### Register

Append to `assemblyintegrity.txt` — **append only, never edit existing rows**, and never add the test
harness's own MVID. Then verify the file: existing rows byte-identical to the backup, every new row
present, no duplicates.

Then **hand it to the operator for approval and deployment.** This is a human gate. The platform is
restarted as part of it.

### Confirm

```powershell
dotnet run --project <mvid-test> -c Debug -f net8.0    # expect marker=REAL
```

`marker=DECOY` after deploying means the rows did not take, the platform was not restarted, or the
row came from a different runtime/OS than the caller.

---

## Platform coverage — what is published, and what is not

| RID | status |
|---|---|
| `win-x64` | published |
| `linux-x64` | published |
| `osx-arm64` | published |
| `osx-x64` (Intel Mac) | not built — add the RID to the build script when wanted |
| `linux-arm64` | not built — add the RID to the build script when wanted |

**CORRECTED 2026-08-21.** These were previously described as blocked on hardware, because the
protection hash was believed to require running the binary on the target architecture. It does not —
see Step 4. The hash comes from the compiled dll, which the cross-compile produces on the build
machine for any RID.

What genuinely needs the target platform is **platform blessing of the Bridge/ASK chain** (Step 2),
and that is per-LIBRARY-VERSION, not per-build. With Bridge/ASK unchanged, adding a RID is a build
script edit and nothing more.

## Step 3 — Build the agent, all platforms

```powershell
dotnet publish HexaEight.Agent\HexaEight.Agent.csproj -c Release -r <rid> `
  --self-contained true -p:PublishSingleFile=true `
  -p:IncludeAllContentForSelfExtract=true -p:PublishTrimmed=false -o dist\agent-<rid>
```

RIDs: `win-x64`, `linux-x64`, `osx-arm64`.

- `IncludeAllContentForSelfExtract=true` is the shipping flag. It puts the managed assemblies on disk
  so `verify-libs` can check them. Without it there is nothing to verify, and a user has no way to
  confirm the libraries are ours.
- `PublishTrimmed` stays **false**. Trimming removes reflection targets the engine and JSON paths
  depend on.
- `RuntimeFrameworkVersion` is pinned in the csproj. Do not float it.

---

## Step 4 — Measure the PROTECTION HASH, per platform

**NO TARGET MACHINE IS NEEDED. Hash the compiled dll in `obj/`, not the extracted one.**

The protection hash is SHA-512 of the entry dll. `PublishSingleFile` embeds that dll **unchanged**,
so the copy sitting in the build output is byte-identical to the one a running binary extracts:

```bash
O=HexaEight.Agent/obj/Release/net8.0
for rid in linux-x64 osx-arm64 win-x64; do
  printf "  %-10s " "$rid"
  shasum -a 512 "$O/$rid/hexaeight-agent.dll" | cut -c1-128 | tr 'a-f' 'A-F'
done
```

**PROVEN, 2026-08-21.** The linux-x64 hash was measured both ways — extracted at runtime from
`~/.net/hexaeight-agent/<dir>/`, and read straight from `obj/` — and the two are identical:

```
8E5F401B0E917ECA0F6BFF97F292D70581D288F8F35A19BFD88183B9E00C3ACB98DEA68725AB5EB2977C97877A5CF8379DE4F97D0991A7B91CF2421E7D7D4422
```

The win-x64 hash was likewise confirmed against a real extraction on Windows.

**Consequence: macOS is a first-class RID with no Apple hardware.** The IL is produced by the
cross-compile, so its hash is available on the build machine. A Mac is needed ONLY for platform
blessing of the Bridge/ASK chain, which is per-LIBRARY-VERSION — while Bridge/ASK stay put, no
release is ever blocked on a Mac. The same argument closes `linux-arm64`: the obj dll exists for any
RID `dotnet publish` accepts.

### The old method, and why it is now only a cross-check

Running `--probe` and hashing `~/.net/<exe-name>/<dir>/hexaeight-agent.dll` still works and is worth
doing once per release as an independent confirmation. It has two traps the obj method does not:

- **`--probe` must run FROM AN IDENTITY FOLDER** (`env-file` + `hexaeight.mac`). Elsewhere it returns
  **2**, which reads exactly like "the platform does not trust this build" and is not. That cost time
  on 2026-08-21 before the cause was spotted.
- **The extraction cache is keyed on the EXECUTABLE FILENAME**, and every release ships the same
  name, so the directory accumulates one entry per release. `rm -rf ~/.net/<exe-name>` first, or you
  may hash an older build and publish a hash that gates nothing.

The exit code does not matter when you only want the hash: extraction happens before the licence
call, so the dll is on disk even when the probe fails (134/SIGABRT on macOS without an identity,
2 elsewhere).

**`--probe` = 0 is still the gate for shipping.** Run it once, from an identity folder, on the
platform you have. It proves the platform trusts the build; the obj hash only tells you which build
it is.

### Worked example — 2026-08-21, agent-source-only release

Changed: `ExternalHost.cs`, `Program.cs`, `AskAgent.cs`, new `VouchStore.cs`. No Bridge, no router,
no library version change — so Steps 1 and 2 were skipped entirely, per Step 0.

```
PROTECTION HASH (SHA-512, entry dll — goes in ApprovedBuilds)
  linux-x64   8E5F401B0E917ECA0F6BFF97F292D70581D288F8F35A19BFD88183B9E00C3ACB98DEA68725AB5EB2977C97877A5CF8379DE4F97D0991A7B91CF2421E7D7D4422
  osx-arm64   F66B6A2DCF8CE9F2B214B18A3E21D9615878EEE2007FFD22F4B33165B4F6A95AF8F9439AA7472EFD276DBB089056DCB07E829589D68BA055C0611CFDB8A876D7
  win-x64     3CDBAE777CE267078E2669FFED314CDCBBAC0E0935267838A6164C3CDDF69DC8FE58AC3265F7D6E18EA07282AB2A2C14B15889B46FAED6830E8480667DA2AA03

SHA-256 (download verification — never appears in an allowlist)
  linux-x64   1A9D7DBAFB04EE02FC03BD5290EAE049847D7FC634FD92886335AC6CE1368D93
  osx-arm64   DFE47B72BA8139329A5941CD735439F4AE7CB7D7F1CB709A2FA2084DAEB34BA8
  win-x64.exe 12F49F9FAF299E2BF6266C6C5A41DCFF118D7AF495103E3FF7ECB4E605290146
```

`--probe` on linux-x64, run from `~/hbia-agent04`, returned **0**.

## Step 5 — Add the hashes to HexaEight.Activate

In `ApprovedBuilds.cs`: bump `ListVersion`, add one entry per RID with a label naming the release and
the library versions.

**Keep the previous release's hashes.** The list is applied additively by agents in the field, and
dropping a build refuses every peer still running it — the coordinated outage the list exists to
prevent. Retire a build by replacing it, not by removing it. To actively withdraw a compromised
build, add it with `Allow = false`: omission cannot revoke, because agents that already approved it
would keep accepting it.

Bump the package version, `dotnet pack`, then **verify the shipped dll actually contains every
hash** — a stale build is easy to produce and impossible to spot afterwards:

```powershell
# search the assembly's UTF-16 string heap for each hash prefix
```

---

## Step 6 — GitHub release

Binaries do not belong in git. They are release **assets**; the repo holds docs and process only.

Asset paths are wherever `buildagent-release.sh` wrote them — **`dist/release/agent/`**. This doc
said `dist/release/bin/` until 2026-08-21; following it literally fails at the very last step,
after every other part of the release is already done.

```bash
gh release create <tag> \
  dist/release/agent/hexaeight-agent-win-x64.exe \
  dist/release/agent/hexaeight-agent-linux-x64 \
  dist/release/agent/hexaeight-agent-osx-arm64 \
  dist/release/agent/HASHES.md \
  --title "<title>" --notes-file notes.md
```

Tag format: `v<yyyy.mm.dd>-r<n>`.

`HASHES.md` must carry **both** hash families — SHA-256 per download, PROTECTION HASH per platform —
and say plainly which is for what.

---

## Step 7 — Publish HexaEight.Activate

Publish to nuget.org **last**, after the agent binaries are up. The tool's job is to approve builds
users can actually download; shipping a list that names builds nobody has yet is backwards.

Then confirm end to end from the published artifacts, not your build output:

```bash
dotnet tool update -g HexaEight.Activate --no-cache
hexaeight-activate verify-env          # licence, libraries, list sync, self-update check
hexaeight-activate approve-builds --list
```

---

## The enforcement test — run it before announcing

Prove the gate both refuses and admits. Refusal alone is not a pass: a gate that refuses everything
looks identical to one that works, and we shipped that state once.

1. Enforce: `approve-builds --tighten`. Start the agent; it should log
   `approved builds: N rule(s), ENFORCING`.
2. Call it from an unapproved build. Expect **403** and, in the agent's log:
   `[external] DENY <sender>: Bridge gate: no matching allow rule (or explicit deny)`
3. Approve that caller — **leave the agent running**. It should log
   `approved builds: reloaded from disk, N rule(s) now in force`.
4. Call again with the same binary. Expect **200** and a real reply.

Step 4 is the one that matters. Steps 1–3 passed for an entire day while the gate was structurally
incapable of admitting anyone, because it matched on a field that is empty on the wire.

A **404** or a JSON parse error in the log is not a refusal. 404 means the route is not mapped
(`external` block missing from config); a parse error means something else broke. Neither is a pass.

---

## Symptoms and causes

| symptom | cause |
|---|---|
| `--probe` = 2, but `verify-libs` says every assembly matches nuget | self-contained runtime rows missing from `assemblyintegrity.txt` |
| `--probe` = 2 and you are NOT in an identity folder | that is the cause. `--probe` needs `env-file` + `hexaeight.mac` in the CWD; it returns 2 anywhere else and reads exactly like distrust |
| Protection hash does not match what a peer expects | hashed the wrong extraction dir. The cache is keyed on the EXE FILENAME and every release shares it — `rm -rf ~/.net/<exe-name>` first, or hash `obj/Release/net8.0/<rid>/hexaeight-agent.dll` instead |
| A release "needs a Mac" | it does not — see Step 4. Only Bridge/ASK blessing does, and that is per-library-version |
| `marker=DECOY` after deploying rows | platform not restarted, or the row came from a different runtime/OS |
| `KGT: 0` / `FAILED: -6` | ran outside the identity folder, or ASK's own rows are not registered |
| Agent refuses everyone after `--tighten` | gate matching on an empty field — fixed in Bridge 1.9.20; before that, unwinnable |
| Allowlist reads back empty | envelope not unwrapped before parsing — fixed in Bridge 1.9.19 |
| Approving a build changes nothing | wrong hash: `--add-file` guessed the wrong file for that publish shape. Use `--add-hash` |
| Everything decrypts to empty string in a test harness | the harness references the Bridge **project**, not the published package. A source build is unblessed and silently returns empty |

That last one deserves emphasis: a probe built against `<ProjectReference>` measures nothing, because
every decrypt returns an empty string with no exception. Always reference the published package.

---

## Open work

Tracked here because it is release-shaped: each item ends in something published.

### 1. `linux-arm64` and Intel Mac (`osx-x64`) — NOT blocked any more

Both were listed here as blocked on hardware. They are not: Step 4 shows the protection hash comes
from the compiled dll, which the cross-compile produces for any RID. Adding either is a one-line edit
to the RID loop in `buildagent-release.sh` plus an `ApprovedBuilds` entry.

The only remaining per-platform requirement is Bridge/ASK blessing (Step 2), which is per-library-
version. While those stay put, a new RID needs no machine of that architecture.

### 2. Working examples

The agent is proven at the protocol level — an unapproved build is refused, an approved one is
admitted, hot reload works without a restart. What does not yet exist is a customer walking from
"licence purchased" to "my agent answered a question", without reading this file.

Needed:

- A minimal caller in each supported language, doing the DDE handshake against `/external/incoming`.
  The C# sample under `samples/external-caller` is the reference; it is currently a test fixture and
  reads like one.
- A worked agent-to-agent example: two identities, one authorising the other, showing where the
  approved-build gate sits in that flow.
- An engine configuration that a reader can copy — the config on the WSL box has thirty engines and
  is a poor first example.

### 3. Website deployment documentation

The gap a paying customer hits first. From a purchased licence to a running agent:

1. `cpucores` — a licence must cover this machine's cores, and this is checked **before** buying
2. `dotnet tool install --global HexaEight.Activate`
3. `install-agent` — download and verify
4. `newtoken` — interactive: licence code plus QR approval in the Authenticator app
5. `--init-policy` — locks the agent down and gates it on the running build's origin
6. Configure engines and start
7. `approve-builds --tighten` when the agent should accept only known builds

Points that must be in the docs because they cost time when missed:

- **Every command runs in the identity folder.** "No identity in this folder" is the most common
  first failure and does not read like a working-directory problem.
- **`hexaeight.mac` is machine-bound and must never be copied.** Hardlink it to share one licence
  between programs on the same machine.
- **One identity per machine.** Provisioning scripts that clone a VM image with an identity in it
  will not work.
- **What cannot be automated:** `newtoken`, `renewtoken`, `--init-policy`. Anyone scripting a
  deployment needs to know where the human step falls.
- **Verification is a step, not a footnote:** `--probe` for platform trust, `verify-libs` for the
  libraries, and the fact that `verify-libs` finding nothing is itself a red flag.
- **Keeping current:** `verify-env` on a schedule refreshes the approved-build list, so a peer that
  upgrades is not refused. Without it the failure looks like an intermittent network fault.
