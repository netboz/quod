# Deployment review01 disposition

The exact candidate bodies and diffs will be frozen by prepare_candidate.py
after the reviewed committed260 image has been built and its digest verified.
No job mutation is permitted before that complete packet is reviewed. The
actual version63 job and both canonical ingress bodies are retained here.

The candidate rendering owner is deployment259 prepare_refound.py, retained
in deployment-259-refound/evidence.tar.gz: it transforms the committed
deploy/quod.nomad template with the candidate job/service prefixes, persistent
volume family and per-index gateway tags. The image-only upgrade copies the
actual version63 body; it does not re-render from the general main-job template.

Changing the ingress template text replaces its allocation. The plan must
report one destructive update, and its replacement must become healthy before
browser reload. Consul-data changes alone are handled by the existing file
provider watch. No claim of a restart-free template edit is made.

Count0-to8 places all eight allocations together. The root committee is one
validator (the preserved node0), not eight; eight processes are still required
healthy for the release. The retained wait-for-peer prestart explicitly exits
for NOMAD_ALLOC_INDEX=0. Other replicas discover it through the existing service.
The existing900-second deployment healthy deadline and1200-second observation
deadline are unchanged. Failure leaves explicit maintenance and retained
volumes; the original operation is resolved before any guarded rollback.

The served public certificate fingerprint is recorded before replacement.
quod_client:self_signed/0 uses identity_dir, and quod_client_tls:ensure/1
keeps client_tls.key/client_tls.crt beside the existing node identity. The
unchanged persistent volume therefore retains certificate/key, subject to the
existing30-day certificate renewal rule. Compare the served fingerprint after
route activation and report any actual renewal. No private certificate key or
browser signing key is read or exported.

The suggested allocation-stop/retry alternative is not adopted: it introduces
a port reservation race and repeat stop operations. The already-authorized
maintenance sequence reserves the old browser port before any replacement
backend can claim it and follows the existing ingress runbook. A brief
candidate-only interruption is deliberate. Main and global ingress jobs are
excluded. The actual personal-world and human latest committed records are
captured for exact history comparison; their origins and keys remain local.
