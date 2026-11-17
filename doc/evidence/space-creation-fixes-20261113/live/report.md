# Space creation fixes: 0.7.289 live (2026-11-14)

Rolling upgrade plus a new system ontology and a live ontology edit on the
existing network, root anchor
`C21E011BC94C7B69AD56A4227BED085EF2FA7C536458A5457C410256C1FD3F5E`. No refound,
no data wiped.

## Commits (worktree/pearl-stone)

- `a3c536c8` fix: keep new spaces apart, name them from quod:names, time pies
- `0f7aa3d5` chore: bump to 0.7.289

## Steps and results

1. Gates on the committed tree: server EUnit 4362/0, CT 150, xref, dialyzer
   (`../server-01-*`); client run 02 every step (`../client-02-*`).
2. Image 0.7.289 built and pushed, digest
   `sha256:c8767353b1bdb065709b64d3de32fc85dcd0df32f2521f5a73af68d9710f21f0`.
3. Plan: only the image and `OTEL_TRACES_SAMPLER_ARG` 0.05 to 1 change; the
   trace address stays on conrad (`plan-0.7.289.log`). Rolling upgrade,
   deployment `8c131a83` successful 02:05, 8/8 compute and 2/2 cloud
   (`upgrade-0.7.289-progress.log`, `after-upgrade-status.txt`).
4. `quod:names` founded on node 0 from the image's source (`names-found-01.log`),
   answering 56,802 place names; listed in root as
   `system_ontology(quod:names, 0D5869D9073BD52352E4AD487F41C15EC4D44606166AE1B15B64F33CEA6BE53E)`
   at root height 62 (`names-register-01.log`, `names-anchor.txt`). All ten
   nodes host it, ready, without a restart (`names-fleet-01.log`).
5. `quod:space` edit from node 0: dry run planned 7 predicates
   (`space-plan-01.log`), all 7 applied (`space-release-01.log`).
6. `fleet-verify-01.log`, all ten nodes: root 62, names 1, space 39; name
   default `default_from(space_name)`; free-place rule answers 750 with one
   space straight ahead.

## Left as is

- `/tmp/quod_source_release.beam` and the two `quod_space.pl` copies on node
  0's container disappear at its next restart.
- Spaces created before this release keep their name and place.
- Client installed 2026-11-14 ~02:30, rollback ~/Games/quod-before-spaces-20261114.
