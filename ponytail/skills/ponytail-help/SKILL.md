---
name: ponytail-help
description: Display a one-shot quick reference for Ponytail modes, skills, and Polytoken-compatible invocation.
---

## Modes

- `ponytail lite` — build what was requested and name a lazier alternative.
- `ponytail full` — enforce YAGNI, reuse, standard library, native features, and the minimum correct diff.
- `ponytail ultra` — delete before adding and challenge speculative requirements.
- `ponytail off` — disable automatic Ponytail context for the session.

Use `@skill:ponytail`, `@skill:ponytail-review`, `@skill:ponytail-audit`, `@skill:ponytail-debt`, `@skill:ponytail-gain`, or `@skill:ponytail-help` to invoke a skill. Polytoken does not document a custom slash-command extension mechanism, so native `/ponytail-*` commands are not provided by this integration.

The default mode is `full`. Set `PONYTAIL_DEFAULT_MODE=lite`, `full`, `ultra`, or `off` before launching `pts` to change it.
