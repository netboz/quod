# Pure exact-request construction

Read frozen AGENTS.md. Review source only; no commands/tests/production edits.
Save fable-review.md here. Scope: encode_typed/1 in the existing signed-goal
codec, agent_request_bytes/2 in the existing common primitives, and replacing
the signer's duplicated conversion with that shared codec. Existing wire and
signing/authority contracts remain. Primitive checks groundness; codec checks
all encoding fields and canonical equality of the typed actor and instance text.
It does not parse the goal or grant authority. It can construct expired bytes;
expiry is enforced only by signing/admission owners as before.

Verification: gate01 retained, sandbox EPERM blocked local TLS fixture; 57 tests,
zero failures, three cancelled, exit1. Gate02 with sockets enabled: 57/0, exit0.
Production signing test verifies signature over the exact pure-encoder bytes;
material proof needs no grant or live bridge. GUI transition fixture commits
and reads inert intent through real signed ingress and checks unchanged-read I/O.
No automatic completion, expiry classification or dispatch is enabled here.

Review authority regression, byte identity, malformed terms, atom safety and
whether pure construction remains distinct from governed signing. Prior GUI
question projection was frozen/reviewed separately.
