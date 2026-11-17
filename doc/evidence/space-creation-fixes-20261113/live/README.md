# Going live: space creation fixes (0.7.289)

Order matters: `quod:names` must exist on every node before `quod:space`
draws names from it, and it is founded from the source file in the node
image, so the image goes first.

Live network: root anchor
`C21E011BC94C7B69AD56A4227BED085EF2FA7C536458A5457C410256C1FD3F5E`, job
version 265, node 0 = allocation of `quod.quod-node[0]`.

## 1. Image and rolling upgrade

```sh
cd /home/yan/src/quod_worktrees/pearl-stone
git archive HEAD | docker build -t 192.168.1.11:5000/quod:0.7.289 -
docker push 192.168.1.11:5000/quod:0.7.289
export NOMAD_ADDR=http://192.168.1.10:4646
nomad job plan -var image_tag=0.7.289 -var node_count=8 -var cloud_node_count=2 \
  -var genesis_hash=C21E011BC94C7B69AD56A4227BED085EF2FA7C536458A5457C410256C1FD3F5E deploy/quod.nomad
nomad job run -detach -check-index <index from plan> -var image_tag=0.7.289 -var node_count=8 \
  -var cloud_node_count=2 -var genesis_hash=C21E011BC94C7B69AD56A4227BED085EF2FA7C536458A5457C410256C1FD3F5E deploy/quod.nomad
```

The job file now defaults the trace address to conrad and keeps every trace;
the plan should show the image tag and `OTEL_TRACES_SAMPLER_ARG=1` changing.

## 2. Found and register `quod:names` (on node 0)

`A` = node 0's allocation id. Each script prints one Erlang map.

```sh
Q() { nomad alloc exec -task quod $A /opt/quod/bin/quod eval "$(tr '\n' ' ' < $1)" </dev/null; }
Q names-state.erl      # expect local_state {ok,not_hosted}, catalogue without quod:names
Q names-found.erl      # creates the ontology; prints its anchor
Q names-register.erl   # lists it as a system ontology; prints the place-name count (56802)
```

Then every node should host it within a minute: run `names-state.erl` on each
allocation (`hosted => true`). A node that does not pick it up is restarted
alone (the September route-wait latch).

## 3. Edit `quod:space` (on node 0)

```sh
nomad alloc exec -task quod $A sh -c 'cat > /tmp/quod_source_release.erl' < quod_source_release.erl
nomad alloc exec -task quod $A sh -c 'cat > /tmp/old-quod_space.pl' < old-quod_space.pl
nomad alloc exec -task quod $A sh -c 'cat > /tmp/new-quod_space.pl' < new-quod_space.pl
nomad alloc exec -task quod $A /opt/quod/bin/quod eval 'c:c("/tmp/quod_source_release.erl",[{outdir,"/tmp"}]).'
Q space-plan.erl       # dry run: lists the planned predicate edits
Q space-release.erl    # applies them
```

## 4. Verify, then install the client

`fleet-verify.erl` on every allocation: `names_hosted => true`, a place-name
count, `name_default => default_from(space_name)`, and the free-place rule
answering `750` with one space straight ahead. Then the client export from the
same commit goes to `~/Games/quod` with `client-install01.py` (labels changed).
