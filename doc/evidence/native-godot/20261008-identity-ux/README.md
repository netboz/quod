# Native identity and onboarding

Yan requested the JavaScript client's create/remember/restore experience in
place of mandatory backup import. The native client now generates and persists
a key before network use, creates the account/lobby through existing APIs,
restores its identity and endpoint automatically, and exposes optional encrypted
backup import/export. This supersedes the import-only prototype scope.

The active identity is a private local file, not passphrase-encrypted storage.
Portable backups use the browser's encrypted format. Server code, deployment,
ontologies and browser production code were not changed by this work.

## Verification

The sequential `identity-final-01` run passed:

- Seven Rust tests, including production-browser import of a native encrypted
  backup, generation/restore, private permissions, second-writer rejection,
  corruption without replacement, original-request recovery after restart,
  and disk-write failure during the account-to-lobby handoff.
- Shared browser conformance and nine existing browser contract test files,
  including account enrollment; formatting and Clippy with warnings denied.
- Extension build, resource/scene owner checks, TLS imported-identity flow,
  Linux export and startup of the packaged executable.
- A [three-process onboarding fixture](identity-final-01/onboarding-fixture/result.json):
  generate/save and receive a pending signup; restart and resolve its exact
  signed request before provisioning the lobby; restart again and restore the
  same key, endpoint and lobby automatically.

The [fixture log](identity-final-01/onboarding-fixture/fixture.log) records exactly
two execute requests and one outcome lookup. It verifies Ed25519 signatures,
existing JavaScript request encodings, the retained group selector and the
absence of resubmission. The third launch changes neither the identity nor
connection-settings file's modification time. This uses disposable identities
and a local TLS fixture, not a deployed Quod account.

The [desktop capture](identity-desktop-01/frame.png) shows the real renderer and
revised entry controls. Later changes only refined the explanatory text and
skipped replacement confirmation when no active key exists; `identity-main-03`
checks script loading and `identity-export-03` packages those final changes.
The [manifest](source-manifest.json) freezes source, reference and export hashes.

The first onboarding attempt failed because GDScript could not infer a local
boolean's type; its log and timeout triage remain in `identity-onboarding-01`.
The correction adds the explicit type. The test launcher now execs the engine,
so a harness timeout targets the tested process directly. No failed log or
assertion was removed.

## Scope and outstanding qualification

Production source increased from 2,306 to 3,051 lines: **net +745**, excluding
tests, tooling, resources/configuration and documentation. The growth adds
identity persistence, portable backup export and durable enrollment recovery;
the mandatory import/unlock entry flow was replaced.

The [previous XR limitations](../README.md) and real-node/physical-Vive acceptance
remain outstanding. This increment qualifies identity/onboarding and does not
claim new headset or deployed-server results.
