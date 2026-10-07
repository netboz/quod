# Claude Fable review

## Refound procedure review

**Recommendation: STOP before founding the remaining 17. One required step is
missing from the v2 helper, and enrollment completion is asserted but not
evidenced. Everything else in the plan is sound.**

1. **Blocker:** add the exact `quod:signup` hosting delegation to the founder
   identity. Both signup and lobby provisioning ask that identity to host the
   new ontology, and `node_execution.pl` requires an exact
   `ontology_hosting_policy/2` fact.
2. **High:** prove complete enrollment, not only an installed principal. Record
   manager status `complete`, a stored pointer, and the committed discoverable
   self-hosting fact.
3. **High:** retain v2 deployment inputs and receipts in durable evidence.
4. **Medium:** pass the digest image, eight home nodes, zero cloud nodes, and
   the exact root anchor explicitly during scale-out.
5. **Medium:** guard catalogue and policy publication against conflicting
   duplicates and finish with 18 descriptors, zero rejected rows, and all
   ontologies ready.
6. **Low:** the ontology list, dependency order, templates, source ACL design,
   and exclusion of `quod:physics` and `quod:present` are correct.

The review confirmed that an ordinary new human should receive read-only access
to the declared public source surface of `quod:modelling`; edits still require
the root administrator grant. It also identified the browser's global v1 agent
selector as stale across a root-anchor change.

## Network-scoped browser reference review

**Recommendation: proceed. The change fixes the reported defect, and nothing
found is above low severity.**

The review verified that:

- v1 rows cannot satisfy the post-login `identity && agent` gate;
- pending operations are already filtered by signing key and root network;
- login retains `entering=true` until the network-scoped selection is installed;
- account callbacks carry their network rather than reading asynchronous React
  identity state;
- stored IDs are recomputed from validated fields; and
- generated HTML and chunks consistently reference the v2 implementation.

Low findings applied after review:

- type `AccountOptions.onAccount` with the required network;
- validate the requested network before filtering an empty store;
- remove the superseded v1 localStorage key;
- keep manual v1-reference loss explicit in release notes/evidence;
- report malformed v2 rows as damaged storage; and
- test same-network replacement when removing an active reference.
