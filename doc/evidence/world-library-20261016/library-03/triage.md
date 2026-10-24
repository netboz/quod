# Empty-library enumeration failure

Combined founding now succeeds. The first `world_library/1` read kills its
proof worker at the existing heap bound, before any creation or entry action.
The retained test storage path appears in `run.log`.

The generic `instance_of(Class, voxel_setting(W, Key))` rule first called
`instance_of(voxel_world, W)` and only afterward constrained `Class` through
`voxel_parameter/5`. Enumerating worlds therefore selected that generic rule
again with another unbound world, recursively, even for an empty library.
The follower frames in the heap trace are a consequence of this recursion.

Resolve the class through the finite parameter relation before asking for world
membership. Add an exhaustive empty/nonempty enumeration regression. Preserve
the worker heap bound and follower semantics; neither is the cause.
