# M4-R2 reporting correction after immutable boundary01

This separately labelled addition corrects the exact assertion attribution in
the frozen M4-R2 handoff/qualification/failure summary. It changes no production,
test, runtime, supplied build input or product result. Boundary01 remains intact:
snapshot543cc3ac764bf15add7e88b450a104c992e3caabf92c00d508bc39e3fb1f1f2a.

The cold native cases fail at different assertions:

- native-vive-final01 passes valid-head and layout checks, then fails
  `hidden desktop container keeps the actual XR scene rendering cycle 1`.
- native-vive-final02 and final03 pass interface start and invalid-startup
  calibration refusal, then fail `real runtime supplies fresh stereo head frames
  cycle 1`, before the later rendering assertion is reached.

Their API dumps separately observe zero swapchains and90/91/91 empty EndFrame
submissions. Those observations remain valid, but do not convert final02/03's
earlier valid-head failures into rendering-assertion failures or establish the
cause of missing rendering. No returned-code/pixel/transform evidence is inferred.
The phrase “cold hardware exported render assertion failure” in boundary01's
qualification and corresponding handoff/failure prose is superseded here.

Exact final03 client log SHA256:
73ebb67e92b0d4ae6e832f722a811ec9ff327f7a49427ee44520ade3b4762217.
Full earlier logs/receipts remain unchanged. Final source-only/software passes,
all native failed campaigns, original desktop stalls, pinned-engine errors and
physical acceptance limits retain their previous dispositions. No test rerun.

The new immutable boundary02 shares every unchanged actual byte from01 by
verified hardlinks, including all9071 output/dependency objects. Its full source
base/binary patch/untracked archive includes this correction, corrected scoped
qualification and the complete read-only findings batch. It performs another
actual complete source reconstruction outside every checkout. Complete final
client/runtime materializations from01 remain applicable because all output/
dependency indexes and bytes are identical; they are reused, not rerun or copied
as build inputs. No existing snapshot/file is rewritten and no cleanup occurs.

The authoritative reporting handoff is
[godot-m4-r2-reporting-addendum.md](../../../nimbalyst-local/handoffs/godot-m4-r2-reporting-addendum.md),
together with the preserved original full handoff. Final completion carries both
boundaries' actual hashes and the corrected assertion distinction.
