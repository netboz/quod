# Erlog publication and dependency pin complete

Commit [`5cad93c71579f138e053b3bb971c050bf2dacb7c`](https://github.com/netboz/erlog/commit/5cad93c71579f138e053b3bb971c050bf2dacb7c) is published on `codex/stage2-policy-diagnostics`, fetched into pearl-stone, and pinned in both `rebar.config` and `rebar.lock`.

The already attached Erlog checkout was at the same base with clean target files. Exactly the three tested files were copied there and committed through the required editor tool. Committed file hashes match the frozen tested patch. Inherited generated application/scanner files were preserved. Quod implementation remains in pearl-stone and Quod is uncommitted.

Automatic review rejected the first push before process creation. The exact rejection, subsequent explicit desktop publication confirmation, successful push and remote/fetch verification are retained here. No uncertain push was replayed or existing remote branch overwritten.

A normal dependency checkout refused the locally modified source files despite their exact match to the new revision. Its true failure is preserved. After confirming no staged changes and exact committed source matches, mixed reset aligned only HEAD/index; working-file hashes before and after are identical. The prepared dependency patch was then applied successfully. Both dependency files pass Erlang syntax consultation. Runtime tests were not repeated because the dependency source is byte-for-byte identical to the already validated source.

The source/evidence freeze `stage2-remaining-admission-applied01` remains immutable. Publication has a separate supplement `stage2-remaining-admission-publication01`. The original aggregate 30-second/three-renewal acceptance remains failed and open. No deployment, user-store access/migration, cleanup, hardware test or Quod commit occurred.
