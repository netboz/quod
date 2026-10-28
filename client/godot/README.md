# Clean Godot client

This Linux .NET client adapts Quod's signed protocol and portable GUI model.
Identity creation/import happens offline. Connect authenticates the original key,
recovers original account/instruction results and opens the ordinary black S0.
Offered forms supply their controls, fields, revisions and binder; Save/Reset use
the existing human instruction → governed personal-agent execution route.

```sh
python3 client/godot-tools/run.py --bootstrap --build
python3 client/godot-tools/run.py -- -- --profile /absolute/private/profile
python3 client/godot-tools/run.py --export
client/godot/dist/quod.x86_64 -- --profile /absolute/private/profile
```

The launcher pins the M0-qualified Godot4.7.2 .NET engine/export templates,
BouncyCastle2.7.0, SDK10.0.112 and runtime10.0.12. It does not load the old Quod
Rust core or GDExtension. Build tools and package caches stay under the ignored
client build directory. Distribute the complete self-contained export directory.

Active keys use a private0700 directory,0600 file, one writer lease, atomic
replacement, file/directory sync and read-back. They are plaintext active keys;
normal restoration has no backup passphrase. Encrypted portable backups use the
existing PBKDF2-SHA256/AES256-GCM format and a separate passphrase. Import targets
an empty profile; a damaged or uncertain store is never replaced silently.

Enter an HTTPS origin and, when needed, an explicitly trusted CA PEM. Certificate
chain, validity and hostname checks remain enabled. Endpoint changes disconnect
the current consumer. An imported key without an account reference first checks
its retained signup receipt; lookup failure cannot provision a replacement.
The setup description names the policy-selected existing account storage for S0.

Native controls support keyboard focus/editing and mouse interaction. Closing a
form cancels local/opening work and retains uncertain signed work. Only explicit
original-outcome reads follow uncertainty or restart; reconnect never dispatches
saved work. Source inspection subscribes to its existing Prolog authorization
before reading a cursor snapshot, and withdraws content on invalidation or denial.
Deferred questions retain their existing preparation/HUD/answer lifecycle.

**Create / operations** selects an existing storage identity, its local class
and an offered form. Catalogue/account/current-space identities are advisory;
an exact namespace/anchor can open other existing storage. The server validates
composition and permission. Space forms offer finite, rational and infinite
extents, placement and exterior choices through the same generic binder. The
shared mark adapter draws solid boxes, exact finite edge boxes and groups,
and picking opens operations on the exact depicted subject. It creates no
collision or local simulation. Creation leaves A in the current space.

Submitted drafts stay locked; explicit defaults start another operation after
the original outcome is known. Changed schemas retain compatible draft fields
but require explicit adoption. Recovery displays original result bindings and
returned subjects through the existing signed outcome owners.

Entry and recursive scene/physics composition are M3.
XR/hardware qualification remains separately reported. The legacy native viewer
retains its uncovered asset/XR obligations until their replacement qualifies;
it is not a dependency of this client. The shared [QUO-62](nimbalyst://QUO-62)
and [M1b evidence](../../doc/evidence/godot-m1b-20261028/README.md) retain the M1
qualification. [QUO-63](nimbalyst://QUO-63) and the
[M2 evidence](../../doc/evidence/godot-m2-20261028/README.md) track additional-space
qualification. The explicit `--qualification` application flag is used only by the
retained exported-application test driver; it supplies no domain permissions.
