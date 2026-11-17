# Claude Fable attention review disposition

Yan requested a consultative review. Read-only Fable session `4fcd30e1-9405-4f6e-84ca-d5d1a3835241` reviewed the exact eleven-file packet `attention-claude-277-01`; it changed no files and ran no tests. These are coordinator dispositions against the current source and retained receipts, not new runtime results. The sealed attention-277 result remains unchanged.

## Confirmed source risks

- `Main.cs` `FitHomeViewport()` clamps the remaining home scene height to **1..360 px**. Expanded native chrome can therefore leave the scene effectively invisible. Reproduce with the Account/Tools/status shells open before choosing a readable scene floor and scroll behavior.
- `QuestionHub.cs` withdraws every question panel when the HUD's separate signed view withdraws. `QuestionPanel.Withdraw()` sets `available=false`, replaces the outcome text, and locks the form. A HUD-only re-projection does not restore the panel's own availability; only its separate question view projection does. Reproduce HUD withdrawal/recovery with a still-authorized question view. Any correction must keep the two authorizations separate, retain unknown-outcome text, and never re-enable a withdrawn question view.
- A receiver-selection error leaves the hub `notice` visible after a later committed receiver selection. Clear that notice only on accepted recovery.

## Conditional concerns

- `QuestionHub.cs` marks every HUD-kept id `Discovered=true` even if the panel's question view was disposed by `RetireQuestion()`. An accepted reappearance of that exact id could count an unusable panel. The ontology normally consumes/removes the exact question; qualify a real or deterministic stale-notice sequence before changing resurrection behavior.
- Complete question and actor references are in tooltips. Their visibility in the spatial texture is unqualified. A finite native software probe should precede any display change; HMD readability remains open.
- The global `accounts.Uncertain` guard may conservatively disable unrelated Cancel actions. Narrowing it needs an original-work isolation test, not a source-only edit.
- The refusal message lacks a reason. Check whether the actual definite reply carries one before promising it in UI text.

## Finding not sustained

Fable could not see whether `SignedSession.Execute()` journals before its first await. Current `Transport.Execute()` synchronously updates `Pending` before its first send await, so the current before/after pending-work capture has the required ordering. No change to the executor is warranted from this review.

## Evidence accounting

`attention-qualified01-run` actually exited **1** at `qualify.py:134`: its browser-log check expected a specific `# pass 33` text. The retained `attention-qualified02-run` exited **0** and emitted the selected-gate result. Neither record is relabelled. The signed certified-negative presentation attempts remain failed, so the `Applied` and refusal wording has source support but lacks a complete dynamic negative gate. The selected software result does not establish a packaged, human, HMD, full-release, or historical-shutdown acceptance.
