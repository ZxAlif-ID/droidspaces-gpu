## What changed

<!-- one or two sentences -->

## Verification on a real device (required)

Paste the command(s) you ran and the output that proves it:

```
(paste output here)
```

- [ ] `bash -n` clean on all touched shell scripts
- [ ] `shellcheck -x --severity=warning install.sh scripts/*.sh demo/gen_header.sh` clean
- [ ] Scripts remain idempotent (re-run does not break)
- [ ] Docs updated in the same PR (if behavior changed)

## Checklist

- [ ] No system paths overwritten (`/usr` untouched; `/opt` + `/usr/local/bin` only)
- [ ] No `curl | bash` patterns introduced
- [ ] CI green on this branch
