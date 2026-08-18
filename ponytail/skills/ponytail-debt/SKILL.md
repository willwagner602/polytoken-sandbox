---
name: ponytail-debt
description: Harvest every ponytail: comment in the repository into a debt ledger showing the deliberate shortcut, its ceiling, and its upgrade trigger.
---

Scan source files while skipping `.git`, dependency directories, and build output. Find comments containing `ponytail:` and report one row per marker:

```text
<file>:<line>, <what was simplified>. ceiling: <the named limit>. upgrade: <the named trigger>.
```

Mark entries without an upgrade path as `no-trigger`. End with `<N> markers, <M> with no trigger.` If none are found, output `No ponytail: debt. Clean ledger.` Read only; do not modify files.
