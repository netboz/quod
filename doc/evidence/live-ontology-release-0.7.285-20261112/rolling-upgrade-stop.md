# Rolling upgrade to 0.7.285 stopped (2026-11-12)

Yan chose the rolling upgrade plus live ontology edit, with a refound as the
fallback "if it comes too complex, too long".

## What happened

- 18:16 CET: `nomad job run` for image 0.7.285, same anchor
  `C21E011B…3F5E` (`upgrade-plan.log`: only the image changes).
- `quod-node[0]`, `quod-node[1]` and `quod-cloud[0]` restarted healthy on
  0.7.285.
- `quod-node[2]` (kp_e5537134, on caton) and `quod-cloud[1]` exit with code 1
  about three seconds after every start. Nomad failed the deployment at its
  20 minute progress deadline (`after-upgrade-status.txt`). Nodes 3 to 7
  stayed on 0.7.283.

## Cause

Not this release. The node exits in `quod_namespace_manager:init/1`:

    {node_actor_bootstrap_failed, root_unavailable}
      quod_namespace_manager:node_actor_bootstrap/0 (line 901)

`quod_node_actor:bootstrap/0` finds a node-actor pointer that is still
*pending with a reference* and calls `pending_bootstrap/1`, which goes through
`quod_ontology:prepare_host_join/3` to `root_storage/0`. At that point
`quod_app:start/2` has just set `namespace_desired` to an empty content map,
so `root_storage/0` always answers `root_unavailable` and the application
start fails. A resolved pointer takes `bootstrap_pointer/1` and does not need
root.

On disk (`/var/lib/nomad/host_volumes/<id>/identity/node.actor`):

- node 2: 740 bytes, written 2026-11-10 16:28, the pending record;
- nodes 0, 1, 3, 5: 203 bytes, the resolved pointer.

So node 2's enrolment was never completed on disk after the 2026-11-10
refound. It ran for two days because nothing restarted it. Any restart of
such a node fails the same way, on 0.7.283 as well: the boot code is
unchanged between 0.7.283 and 0.7.285 (the only `src/` changes are
`quod_client_view.erl` and `quod_client_goal_parser.erl`).

## What was ready on the rolling route

The live ontology edit was planned and dry-run on node 0 before the upgrade
(`live-plan.erl`, `live-plan-01.log`): 14 predicate edits for `gui_scene.pl`,
1 for `quod_gui.pl` and 29 for `quod_space.pl`, all planned without error. It
was not applied.

## Decision

Repairing or bypassing a pending enrolment record on a live validator is
identity-state surgery outside this release. Stopped here and switched to the
refound Yan authorized. The boot defect remains to be fixed: a refound can
leave nodes in the same pending state, and they will fail on their next
restart.
