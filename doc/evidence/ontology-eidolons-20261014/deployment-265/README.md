# Candidate 0.7.265 deployment

Yan authorized committing all current repository changes, deployment, and ledger
erasure if needed. The combined implementation, GUI framework changes and existing
workspace evidence are committed as `33a5f4119a1d8fee3a1ef57abb230615b543992d`.
The separate release label is `2b26d83718f32fb4d4c713a570a0c9801099d0c9`.

The candidate uses the verified image
`192.168.1.11:5000/quod:0.7.265@sha256:2ebf5e8b84e5eb7b5bb36ea3f5330017b3db8e4aa7845d0f3020c3dbe2ceffcc`.
Its exact committed inputs, isolated network-disabled boot, shipped browser assets
and registry digest were checked before fleet changes.

## Clean foundation

The live candidate had outcome format 8; the combined source requires format 9
and refuses 8. The existing clean-refound procedure installed a new volume family
on the same hosts. All eight old volumes remain intact and offline. No old ledger
was rewritten or deleted. The separate main `quod` job remains version 246 / modify
index 826727. The stable ingress remains version 1 / modify index 846370.

The indexed sequence was cold maintenance, one founder with browser access
disabled, existing ontology creation/catalogue/enrollment/signup delegation, a
cold seal of that founder, and eight anchored joining nodes. The seal was needed
because Nomad's initial scale plan would retain the founder's temporary config.
That failed plan submitted no mutation. Every submitted change retained its exact
request, index and response; no uncertain mutation was resubmitted.

Candidate job `quod-finality-candidate-v6-20260926` is version **77**, modify index
**857357**, with eight healthy nodes and 18 ready system ontologies on each.
The new root is
`F747AB5E6A43F61C0207C3D8BD9F7537D1840FBAFB3E50FAF22E0F4688096698`.
Existing candidate accounts belong to the old foundation; users must sign up
again at the unchanged [browser origin](https://192.168.1.10:30519).

## Verification

All eleven clean sequential release gates passed with unchanged frozen inputs:
35 native tests in debug and release, Clippy, 180 client tests, UI build/lint,
3,974 EUnit tests, 148 Common Test cases, xref, Dialyzer and release assembly.
All 365 committed browser files matched the clean build. The live HTML and its
three entry assets also matched the committed bundle.

Real signed requests from a key-bound signup applicant without administrator
authority selected ordinary ontology Eidolons on all 17 public system targets.
Source workspaces were read-only; policy, declared interfaces and live routes used
the existing text lenses and complete cursors. Exact target references, unchanged
source repeats, wrong-anchor refusal, private-root source/recipe refusal and
invocation refusal passed. These checks issued zero execute requests.

One intentional gateway restart recovered the same root and all 18 system
ontologies. Source, policy and interface hashes matched for every public target,
and the access refusals still held. Route generation is live and was not asserted
immutable. The gateway has one intentional restart; the other seven nodes have
zero. Every node retained enrolled principal custody and format 9 indexes.
The temporary founding helper is absent after restart. Local production-owner
tests in the release gates cover editable/denied owned targets, stale permissions,
transactional edits and unchanged inspection without history/projection/I/O work;
the live checks above made no permission-probe mutations.

The first restart observation ran before the Erlang control endpoint was up.
The restart itself succeeded and was not repeated; a later subscribed runtime
observation completed. Initial preparation, metadata-read, asset-URL and launcher
failures are retained, along with the failed scale plan and all true child exits.
No browser profile or human private key was exported. Broader GUI hardware
acceptance is not inferred from this deployment.

[Summary](SUMMARY.json), [release gate logs](gate-logs.tar.gz),
[deployment records and operators](deployment-logs.tar.gz), and
[post-restart signed checks](signed-inspection-after-restart.json) retain the
complete evidence. The archives include compiled disposable operator fixtures;
generated Docker contexts and extracted image copies remain in the ignored build
directory.
