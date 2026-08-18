---
name: ponytail-review
description: Review a diff exclusively for over-engineering and identify what can be deleted or replaced with simpler alternatives.
---

Review only unnecessary complexity, not correctness, security, or performance.

For each finding, output one line:

```text
<file>:L<line>: <tag> <what>. <replacement>.
```

Allowed tags: `delete:`, `stdlib:`, `native:`, `yagni:`, and `shrink:`. End with `net: -<N> lines possible.` If there is nothing to cut, output `Lean already. Ship.` Do not apply fixes.
