---
name: ponytail
description: Apply Ponytail's minimal-solution discipline to coding tasks: question YAGNI, reuse existing code, prefer standard-library and native solutions, and leave the smallest runnable check for non-trivial logic.
---

Ponytail is active for coding work. “Lazy” means efficient rather than careless.

## Solution ladder

Stop at the first rung that works:

1. Question whether the feature needs to exist at all (YAGNI).
2. Reuse an existing helper, utility, type, or pattern.
3. Use the standard library.
4. Use a native platform feature.
5. Use an already-installed dependency.
6. Reduce it to one line if possible.
7. Write the minimum code that works.

Apply the ladder after understanding the task and tracing the affected path. Do not simplify away trust-boundary validation, data-loss error handling, security, accessibility, calibration, or anything explicitly requested.

## Intensity

- **lite:** Build what was requested and name a lazier alternative in one line.
- **full:** Enforce the ladder and produce the shortest correct diff. This is the default.
- **ultra:** Delete before adding and challenge speculative requirements before building.

For bug fixes, inspect every caller and fix the shared root cause rather than duplicating guards in callers. Mark deliberate shortcuts with a `ponytail:` comment naming the ceiling and upgrade path. Non-trivial logic needs the smallest runnable check that would fail if it breaks; trivial one-liners do not need a test.
