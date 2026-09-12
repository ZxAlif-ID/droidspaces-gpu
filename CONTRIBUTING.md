# Contributing to droidspaces-gpu

Thanks for your interest! This project documents and automates a very
specific environment (Android-hosted Ubuntu rootfs + Adreno GPU). Changes
are only as good as their verification, so the rules below are strict.

## Ground rules

1. **Verified changes only.** Every claim in the README/docs must have been
   executed on a real target. Include the relevant command output (paste it
   or attach a log) in your PR description.
2. **Idempotency is mandatory.** Every script under `scripts/` must be safe
   to re-run. Guard every destructive or network step with an
   "already done?" check (see existing stages for the pattern).
3. **No system overwrite.** Never install over apt-owned files in `/usr`.
   New components go to `/opt/turnip`, `/opt/vulkan-sdk`, or
   `/usr/local/bin` wrappers that fall back to the system tool.
4. **Shell discipline.** `set -Eeuo pipefail` in every script, `bash -n`
   clean, no unquoted expansions. Run `shellcheck scripts/*.sh` if you have
   it; CI does.
5. **Docs stay honest.** If you change behavior, update the matching doc in
   `docs/` in the same PR. Every documented symptom needs its cause and fix.

## How to submit

1. Fork / branch (`feature/your-change`).
2. Make the change with the rules above.
3. Test locally on your target:
   - `bash -n scripts/*.sh`
   - `sudo bash scripts/00-preflight.sh`
   - full run of the stages you touched + `scripts/70-verify.sh`
4. Open a PR describing: what changed, what you ran, what output proved it.
5. CI must be green (shellcheck, bash -n, demo build, CITATION.cff check).

## Good first contributions

- Newer turnip/Mesa release bumps (test the glibc patch still applies).
- Additional glibc targets (e.g. 2.31 for older rootfs, 2.39 for noble
  native).
- A Debian trixie porting guide.
- More compute demos (matrix multiply, image filters) for the `demo/` dir.
- Translations of the README.

## Reporting bugs

Open an issue with:

- `scripts/00-preflight.sh` output
- `uname -a`, `/etc/os-release`, `ldd --version | head -1`
- the exact failing command + full output
- `vulkaninfo --summary` output (with the three env vars set)

## Code of conduct

By participating you agree to the
[Contributor Covenant](CODE_OF_CONDUCT.md).
