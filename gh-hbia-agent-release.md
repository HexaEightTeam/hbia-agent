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

Run each binary once so it extracts, then hash the extracted **entry dll**:

```powershell
.\hexaeight-agent.exe --probe                       # exit 0 = blessed, 2 = not
$d = Get-ChildItem "$env:LOCALAPPDATA\Temp\.net\hexaeight-agent" -Directory |
     Sort-Object LastWriteTime -Descending | Select-Object -First 1
(Get-FileHash (Join-Path $d.FullName 'hexaeight-agent.dll') -Algorithm SHA512).Hash
```

```bash
./hexaeight-agent --probe ; echo $?                  # Linux: ~/.net/... macOS: ~/.net/...
shasum -a 512 ~/.net/hexaeight-agent/*/hexaeight-agent.dll | cut -c1-128 | tr 'a-f' 'A-F'
```

`--probe` caches its verdict for 60s in `.probe.state`; delete it when retrying.

**`--probe` must return 0 on every platform before you go further.** A 2 means the platform does not
trust that build — usually a missing self-contained row from step 2.

---

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

```bash
gh release create <tag> \
  dist/release/bin/hexaeight-agent-win-x64.exe \
  dist/release/bin/hexaeight-agent-linux-x64 \
  dist/release/bin/hexaeight-agent-osx-arm64 \
  dist/release/HASHES.md \
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
| `marker=DECOY` after deploying rows | platform not restarted, or the row came from a different runtime/OS |
| `KGT: 0` / `FAILED: -6` | ran outside the identity folder, or ASK's own rows are not registered |
| Agent refuses everyone after `--tighten` | gate matching on an empty field — fixed in Bridge 1.9.20; before that, unwinnable |
| Allowlist reads back empty | envelope not unwrapped before parsing — fixed in Bridge 1.9.19 |
| Approving a build changes nothing | wrong hash: `--add-file` guessed the wrong file for that publish shape. Use `--add-hash` |
| Everything decrypts to empty string in a test harness | the harness references the Bridge **project**, not the published package. A source build is unblessed and silently returns empty |

That last one deserves emphasis: a probe built against `<ProjectReference>` measures nothing, because
every decrypt returns an empty string with no exception. Always reference the published package.
