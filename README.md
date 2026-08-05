# HexaEight Bridge Identity Agent (HBIA)

Prebuilt agent binaries for Windows, Linux and macOS.

An agent runs under a HexaEight identity and talks to other agents over DDE-encrypted envelopes.
There is no API key and no shared account: the envelope proves who is calling, and the receiving
agent decides whether to answer.

Each build is **self-contained** — it carries its own .NET runtime, so nothing needs to be installed
to run it.

## Install

Use the tool. It picks the right binary for your platform, downloads it, and **verifies it before it
can run**:

```bash
dotnet tool install --global HexaEight.Activate
mkdir my-agent && cd my-agent
hexaeight-activate install-agent
```

The expected SHA-256 ships *inside* that package, so it does not come from the same place as the
download. A checksum published next to the file it describes proves only that the two were produced
together — whoever can replace one can replace the other. Because the hash arrives via nuget.org
(TLS, a reserved `HexaEight.` prefix nobody else can publish beneath, and your own decision to
install the tool), GitHub only has to serve bytes. A substituted file fails the comparison and is
**deleted before it is ever marked executable**.

Re-running is safe: an already-verified install reports that and exits without downloading again.

### Or download by hand

Take the file for your platform from the [latest release](../../releases/latest) and check it
against `HASHES.md`:

| platform | file |
|---|---|
| Windows x64 | `hexaeight-agent-win-x64.exe` |
| Linux x64 | `hexaeight-agent-linux-x64` |
| macOS Apple Silicon | `hexaeight-agent-osx-arm64` |

```bash
sha256sum hexaeight-agent-linux-x64                      # Linux
shasum -a 256 hexaeight-agent-osx-arm64                  # macOS
certutil -hashfile hexaeight-agent-win-x64.exe SHA256    # Windows

chmod +x hexaeight-agent-linux-x64                       # Linux / macOS
xattr -d com.apple.quarantine hexaeight-agent-osx-arm64  # macOS, if Gatekeeper objects
```

Intel Macs are not covered — see *Platform coverage* below.

## Verify what you have

Two further checks, answering different questions. Order matters.

**Are the libraries inside the ones we published?**

```bash
./hexaeight-agent --probe        # run once so the assemblies land on disk
hexaeight-activate verify-libs   # compares each assembly against nuget.org
```

`verify-libs` finding **nothing** is itself a red flag. Official releases place their assemblies on
disk precisely so they can be checked; a build with nothing to check was not packaged the way we
publish, and you should treat it as suspect rather than convenient.

**Does the platform trust this build?**

```bash
./hexaeight-agent --probe ; echo $?     # 0 = blessed, 2 = not
```

## Approved builds

Every envelope carries a **PROTECTION HASH** — the hash of the executable that sent it, derived by
the library rather than claimed by the caller. An agent can be told which builds it will accept, so
"only official HBIA may call our services" is enforceable rather than a policy document.

The hashes for this release are published in `HASHES.md`, and they also ship inside
[`HexaEight.Activate`](https://www.nuget.org/packages/HexaEight.Activate), so this works without
anyone copying a hash by hand:

```bash
hexaeight-activate verify-env               # approves the builds HexaEight has blessed
hexaeight-activate approve-builds --tighten # enforce: refuse anything unlisted
```

Self-published agents are first class. If you build your own agent on these libraries, approve it
alongside the official ones:

```bash
hexaeight-activate approve-builds --add-hash <PROTECTIONHASH>
```

Prefer `--add-hash` with a value read off the wire. `--add-file` has to infer which file the build
attests, and that depends on how it was published — a self-extracting single file attests its
extracted entry dll, a framework-dependent app attests its apphost, and `dotnet foo.dll` attests
neither. A wrong guess writes a rule that silently never matches, and the peer is refused forever
with nothing in the log to explain it.

A running agent watches its allowlist, so approving a build takes effect **without a restart**.

## Getting started

```bash
dotnet tool install --global HexaEight.Activate
mkdir my-agent && cd my-agent

hexaeight-activate install-agent   # download + verify the binary for this platform
hexaeight-activate newtoken        # interactive: licence code + Authenticator approval
./hexaeight-agent --init-policy    # locks the agent down, and gates it on this build's origin
./hexaeight-agent
```

Every command runs in the **current working directory**, which must be the folder holding `env-file`
and `hexaeight.mac`. Running from anywhere else fails with "no identity in this folder".

`newtoken` and `--init-policy` need a person — a QR approval in the Authenticator app, and an owner
email. Everything else here runs unattended.

`--init-policy` writes a closed policy — nobody but the owner — and closes the build gate around the
binary that is running, measured rather than guessed. If it cannot measure the hash it leaves the
gate **open** and says so, rather than tightening on a value it is unsure of and locking you out of
your own agent.

## Platform coverage

`osx-arm64` covers Apple Silicon. Intel Macs need a separate build: the platform validates an IL
hash computed per *(assembly, runtime, OS)*, and cross-publishing cannot produce it — the capture
has to happen on that architecture.

## Licence

The agent requires a HexaEight licence. See [hexaeight.com](https://hexaeight.com).
