# LockDown Browser Process-Policy Launcher

A version-pinned companion launcher for **Respondus LockDown Browser 2.1.6.03 (x64)** that removes the *"You must close the following application before starting LockDown Browser"* nag — and both of its process-termination paths — **without modifying the browser executable on disk or any executable page in memory**.

**[简体中文版 / Chinese README](README.zh-CN.md)**

## What it does

LockDown Browser ships with a blacklist of ~1,166 processes it demands you close (Iris, f.lux-style eye-care tools, ToDesk, Sunlogin, TeamViewer, wallpaper utilities…). When it starts it shows the "must close" dialog and kills whatever matched; after you pick your institution's server it also silently sweeps background processes on a timer. This launcher keeps the browser's exam-environment integrity **fully intact** (anti-switch watchdog, tamper checks, event reporting are untouched) while neutralizing only the process-blacklist behavior:

| Browser behavior | With this launcher |
|---|---|
| Startup "must close the following application" dialog | Never shown |
| Startup blacklist kills | Never happen |
| Post-login periodic silent sweep | Never armed |

## How it works (two mechanisms, both heap-data-only)

1. **Startup rule table.** The browser decrypts a 1,166-record process-rule table into its private heap a few seconds after launch. The launcher polls for the table (anchored on four known display names + writable-heap validation), briefly suspends the child, zeroes the first byte of every match string (2,830 strings), and resumes. The startup scan then matches nothing.
2. **Periodic-scan gate-keeper.** ~2 s after the server selection, the browser arms a periodic process sweep by setting one 4-byte flag (`state+0xf388`) exactly once. The launcher polls at 250 ms and zeroes the flag at the instant it is armed (logged as `periodic_scan_gate_cleared`). The sweep never runs.

No code pages are written. The 15 documented `.text` patch sites are kept in [rewrite/dist/patch-plan.json](rewrite/dist/patch-plan.json) purely as a live version fingerprint; they are never applied at runtime.

## Verification (2026-11-18, QEMU/Win11 lab + real machine)

- VM acceptance of the production build: server auto-selected, `policy_data_verified` (1166/2830) → `policy_activated` → `periodic_scan_gate_cleared {armed:1}`, 168 samples × 4 blacklisted decoys **zero deaths**, browser healthy (full evidence in [rewrite/lab/reports](rewrite/lab/reports)).
- Untouched-original control under identical conditions: the nag dialog appears at t≈22 s and the original kills 3 of 4 decoys after "Close Application and Continue" ([control-9aff7cd855d9-result.json](rewrite/lab/reports/control-9aff7cd855d9-result.json)).
- Real machine: activation verified in `%LOCALAPPDATA%\ProcessPolicyRewrite\logs` (`policy_activated`, `periodic_scan_gate_cleared`, clean exit 0); the user's eye-care tool survived a launch for the first time.

Known open edge (documented honestly): a third, intermittent kill path that fires **before** server selection (observed once, <10 s after launch, real machine only). It is behavior-based (display manipulation), not name-based — an inert decoy with a blacklisted name survives 120+ s in the lab. Investigation continues in [rewrite/RESUME-STATUS-2026-11-18.md](rewrite/RESUME-STATUS-2026-11-18.md).

## Usage

1. Install the original LockDown Browser **2.1.6.03 x64** (from your institution's download). Other versions (e.g. 2.1.3.08 x86) are deliberately rejected.
2. Run `VerifyVersion.exe` (read-only check) — it must print `verified=true`.
3. Right-click **Run as administrator** → `LockDownBrowser.NoProcessGate.exe`. It launches the real browser and stays resident to maintain the two mechanisms; browser arguments (e.g. `rldb:...` links) are forwarded.
4. Optional: `Register-Protocol.ps1` routes `rldb:` links to the launcher (supports `-WhatIf` / `-Restore`).

Logs: `%LOCALAPPDATA%\ProcessPolicyRewrite\logs` (launcher events only; no URLs or browser arguments are logged).

## Build & test

```powershell
python build.py                                    # uses the stock .NET Framework x64 compiler
python -m unittest discover -s tests -p "test_*.py" # 17/17 green
```

Requires `pefile` for the Python build helper. Sources: [rewrite/src](rewrite/src).

## Scope and non-goals

- This project is about **letting benign background software coexist** with LockDown Browser (eye-care, input, wallpaper utilities…). It does **not** remove or bypass any exam-integrity control: the anti-switch watchdog, code-integrity checks, secure-event reporting and the exam kiosk boundary are untouched and remain fully functional.
- Only 2.1.6.03 x64 (exact SHA-256) is supported; the version gate is a feature, not a bug.
- Not affiliated with, endorsed by, or supported by Respondus. Provided for interoperability and educational purposes; use in accordance with your institution's policies.

## Repository layout

```
rewrite/
  dist/        launcher + verifier + plan + protocol registration script
  src/         C# sources (ProcessPolicyLauncher.cs, PolicyData.cs, ...)
  plans/       version-pinned byte fingerprints
  tests/       integration + discovery tests (self-built harmless fixtures)
  lab/         QEMU lab tooling, guest scripts, and full experimental evidence
  README.md     technical deep-dive (Chinese)
```

## License

MIT — see [LICENSE](LICENSE). The repository contains no Respondus binaries or derived dumps; users must obtain the original installer from their institution.
