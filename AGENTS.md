# Repository handoff

Read [docs/BUILD-AND-ISSUE-STATUS.md](docs/BUILD-AND-ISSUE-STATUS.md) before
continuing the implementation backlog. It indexes exact verified builds, the
last recorded phone installation, local validation, issue status and remaining
acceptance gates. Historical phase reports retain their original context; the
handoff contains the latest dependency order.

After each verified build, preserve compact evidence and update the build ledger
and affected issue records. Keep implementation, installation and physical
acceptance separate. Do not depend on chat history or `/tmp` as the only record.
Close issues only when their full acceptance is supported by evidence.

Current owner preferences (30 September 2026): do phone-free implementation first;
keep physical acceptance last; defer hosted Actions while credits are exhausted
without disabling workflows; use GPT-6 Sol with ultra reasoning for delegated
agents. These preferences do not claim that device or hosted checks have passed.

Preserve the three pre-existing untracked user documents unless explicitly asked
to change them: `AR-TECHNOLOGY-RESEARCH-2026-09-07.md`,
`IMPLEMENTATION-PLAN-2026-09-08.md`, and `TECHNICAL-AUDIT-2026-09-07.md`.
