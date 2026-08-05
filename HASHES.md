# HexaEight agent — release hashes (2026-08-05, r5)

Built on **Bridge 1.9.21 / ASK 1.9.161 / JWT 1.9.292**, .NET **8.0** self-contained,
runtime pinned to **8.0.28**, single-file with `IncludeAllContentForSelfExtract=true`.

Self-contained means the agent carries its own runtime: nothing needs to be installed to run it,
and the attested hash is identical on every machine of that platform.

## Two different hashes per file — they answer different questions

**SHA-256 of the download** — did the file arrive intact and unmodified?
Check it before you run anything.

| file | SHA-256 |
|---|---|
| `hexaeight-agent-win-x64.exe` | `4FC727D15F6E46152ED5B4DBE56C7FF004901D5514F667680E7E348CA358681D` |
| `hexaeight-agent-linux-x64` | `384BFA57A6D7216C63EA135C6C1B86D1F43D6DDDC60C7CFD750D409478BBDF78` |
| `hexaeight-agent-osx-arm64` | `1DBC782B90CDC910D70556256BBBAC824D5B81D26B78C8EDD718CA14D996E70A` |

**PROTECTION HASH (SHA-512)** — which build is this, as attested on the wire?
This is what a peer's approved-build gate matches on. It is the hash of the **extracted entry dll**
(`hexaeight-agent.dll` in the extraction directory), *not* of the downloaded file — a self-extracting
single-file build attests what it loads, not its wrapper.

| platform | PROTECTION HASH |
|---|---|
| win-x64 | `6230A870E4825659E3A011E7C4FD6ABD80D1BDEC966BBEBC076C519398F4E57F5DD7A54B6B4C0E70967713DDF0A417CCA877A24539E76D1330D5F2D9B9064CEB` |
| linux-x64 | `51652F55027CBB41779BA78317E28CBBC92D0ECFFEA049F3C8FB395E2B26EC48A5C3591453B14298D0E4789995C6C238B710D5C51B6AF6B586EB32523EF7ECD7` |
| osx-arm64 | `8FD1377D7A7A535FD1174F05084B28E81650A52FCFCE210245D3E97C4DCE8A6C12D48432B2E4F2A9E3CF21D961EB685C63433E9FD94CC29C93CD0A251A7F5343` |

All three ship inside `HexaEight.Activate` **1.0.11** (approved-build list **v5**), so
`hexaeight-activate verify-env` approves them automatically and nobody copies a hash by hand.

## Verifying a download

```
# 1. the file is the one we published
sha256sum hexaeight-agent-linux-x64          # compare with the table above

# 2. the libraries inside are the ones we published to nuget.org
./hexaeight-agent --probe                     # runs once so the assemblies land on disk
hexaeight-activate verify-libs                # compares each against nuget.org

# 3. the platform trusts this build
./hexaeight-agent --probe ; echo $?           # 0 = blessed, 2 = not
```

`verify-libs` finding **nothing** is itself a red flag: official releases place their assemblies on
disk precisely so they can be checked. A build with nothing to check was not packaged the way we
publish.

## Why the runtime version is pinned

The platform validates an IL hash computed per *(assembly, runtime, OS)*, so the .NET patch level a
self-contained publish bundles is part of what identifies the build. Left floating, a publish on a
machine with a different runtime pack silently produces different hashes, the platform stops
recognising them, and every agent from that build is refused — with no source change to explain it.

Measured on 2026-08-05: on macOS the SDK's shared **8.0.0** produced entirely different ASK/JWT/Bridge
hashes from the self-contained **8.0.28** build. The agent came back unblessed (`--probe` = 2) while
its libraries verified clean against nuget.org — a state that looks like tampering and is not.

Changing `RuntimeFrameworkVersion` is therefore a release decision: it invalidates every registered
row and requires a fresh MVID capture on all three platforms.

## Platform coverage

`osx-arm64` only for macOS — Apple Silicon. An Intel Mac needs its own capture; the IL hash is
per-OS and cross-publishing cannot produce it.
