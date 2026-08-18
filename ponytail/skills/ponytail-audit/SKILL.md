---
name: ponytail-audit
description: Audit the whole repository for over-engineering and return a ranked list of what to delete, simplify, or replace with standard-library or native equivalents.
---

Scan the whole repository, excluding `.git`, build output, and dependency caches. Review over-engineering only; do not report correctness, security, or performance issues.

Look for dead code, unused flexibility, single-implementation abstractions, one-product factories, delegating wrappers, dead configuration, unnecessary dependencies, and hand-rolled standard-library functionality.

Output one ranked line per finding:

```text
<tag> <what to cut>. <replacement>. [path]
```

Use `delete:`, `stdlib:`, `native:`, `yagni:`, or `shrink:`. End with `net: -<N> lines, -<M> deps possible.` If there is nothing to cut, output `Lean already. Ship.` Do not apply fixes.
