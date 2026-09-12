# Security Policy

## Scope

This repository ships shell scripts, a small C demo, and documentation for
enabling GPU access inside a *root-owned, user-controlled* Linux rootfs
(Droidspaces / proot on an Android device). It runs entirely on hardware the
operator already controls.

## Supported versions

| Version | Supported |
|---|---|
| latest `main` | yes |
| tagged releases (v1.x) | security fixes only |

## What is NOT a vulnerability here

- Running `install.sh` as root inside your own rootfs (it must be root to
  write `/opt` and `/usr/local/bin`).
- The `LD_PRELOAD` shim — it only exports `__isoc23_*` wrappers; it loads
  nothing from user-writable paths and does not alter other binaries.
- Downloading prebuilt turnip from the upstream release page — verify the
  tag you fetch; the installer pins a specific tag by default.

## What we DO care about

- **Script injection via environment** — all scripts must quote variables;
  report any unquoted expansion that can split.
- **Download integrity** — if you can add a checksum verification for the
  turnip tarball (stage 20), that is a welcome PR.
- **The glslc shim writing to /tmp** — the wrapper uses `mktemp`; report
  anything that guesses filenames.
- **Anything that would run commands from repo files without the user
  reading them first** (e.g. curl|bash patterns). This repo intentionally
  avoids that pattern — keep it that way.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting on this repository
(Security tab -> Report a vulnerability), or contact
[@ZxAlif-ID](https://github.com/ZxAlif-ID) privately. Do not open a public
issue for anything that looks exploitable.

You can expect a first response within 7 days.
