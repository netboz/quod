# Candidate founding inputs

Apply `founding-helper.patch` to a build copy of the existing
`doc/evidence/refound-20261007/quod_fresh_systems.erl` operator before compilation.
Keep that historical evidence unchanged. The helper still invokes ordinary
ontology creation, publication and hosting; this patch changes only factory
composition inputs.

The image exposes its single packaged `priv` directory at `/opt/quod/priv`.
The founding helper uses that stable location so retained factory references
survive an application-version change. Prepared creation still freezes source
contents into each new ontology's genesis; recovery never rereads those files.
All candidate nodes must run the same pinned image before founding. The codec
acceptance change is not suitable for a mixed old/new validator fleet; the
separate main network remains unchanged.

The lobby founding dependencies must include exact `rendering_vocabulary/2`,
`modelling_vocabulary/2`, `material_eidolons/2`, `environment_vocabulary/2`,
`environment_eidolons/2` and `gui_vocabulary/2` references from this new network's
catalogue. Use the committed rendering anchor explicitly; the factory no longer
uses a repair action to fill a missing dependency.

Deployment requires full gates and final Fable review. Only the authorized
candidate network may be refounded. Preserve the main network and user key
storage. Freeze the helper, job configuration and resulting identity evidence in
the new deployment campaign; old campaign logs are not release evidence.
