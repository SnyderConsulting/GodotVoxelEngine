# Developer Experience (DX) Notes for Engine Consumers

Keep these principles in mind while shaping APIs, tooling, and demos so engine users can work quickly and confidently.

- Clarity & consistency: predictable naming, stable shapes, uniform error formats; avoid special-case one-offs.
- Fast feedback: short build/test loops, hot reload where possible, immediate and actionable errors/logs.
- Observability built-in: structured logs, metrics, and probes that are easy to turn on; defaults that surface common issues without extra wiring.
- Reduce context switching: docs and hints close to the code/IDE; self-describing APIs; curated, minimal examples alongside source.
- Guardrails with escape hatches: sensible defaults and “pit of success” flows, but clear ways to override when needed.
- Minimal surface & composability: small orthogonal building blocks that compose; avoid sprawling optional params that mix concerns.
- Stable contracts & versioning: avoid breaking changes; document deprecations and migration steps; favor additive evolution.
- Helpful errors: specific messages, likely causes, and next-step guidance; avoid silent failures.
- Tooling fit: scripts/CLIs with obvious flags, good defaults, and clear output; editor/IDE friendliness where possible.
- Usability testing mindset: validate APIs with realistic demo tasks and observe friction points; adjust based on real usage, not just signatures.
