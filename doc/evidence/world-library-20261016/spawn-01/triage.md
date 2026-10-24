The pure candidate test found a production error before any placement claim:
literal `-1` in a Prolog data term reaches the sampler as unary-minus syntax,
not an integer. The sampler correctly rejects that vector as invalid. The
separate `spawn-diagnosis-01` run expanded only the retained failure diagnostics
and confirms `invalid_voxel_field` at that call. The fix evaluates `Outside is -1`
once before constructing the sampler vector and the empty-search sentinel.

The first test draft also referred to a nonexistent extent predicate, in code
not reached by this failure; that assertion was removed before the diagnostic
run. Bounded extents are represented by a clipped field; no such domain query
exists. This test establishes sample clearance and initial chunk selection,
not installed native admission or the blocked end-to-end journey.
