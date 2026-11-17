# Automatic node identity enrollment

Implementation contract for automatic physical-node identity creation. Policy
installation is a governed network change; updating a binary does not edit
retained ontology histories.

## Authority

Enrollment is open, as selected by Yan. A persistent physical key may obtain
one protected ordinary ontology containing its node instance, active key,
explicit ACL, and node methods. It receives no root administrator grant,
arbitrary creation grant, or committee seat. `quod:node` owns the complete
founding recipe and allocation policy. Root delegates to that exact history
and retains its existing `create_ontology/3` action. Administrator invocation
rights alone do not satisfy that action's creation prerequisites.

The allocation must survive acknowledgment: a consumed signup-style receipt
alone cannot prevent a second identity for the same key. A deterministic name
alone is insufficient because independent histories can share a name.

## Creation and placement

A signed applicant request runs at a validator of its source ontology. The
root creation effect runs at the root proof's signer, which can be another
physical node. Its executor and private preparation remain governed by the
existing effect journal. Neither source execution nor a signed caller's key
can choose a different effect executor.

Creation, allocation, and the executing node's ordinary discoverable hosting
intention must commit as one existing atomic group. The hosting declaration
belongs in the custodian's node ontology, not root. The exact custodian must
be tied to the root effect executor; observing the source worker's local node
is insufficient. Founder self-creation records itself as custodian and skips the foreign
hosting write. Its retained operation and the existing effect journal keep
creation recoverable until verified binding and the self-hosting transition.

The applicant's namespace manager then joins the allocated exact identity
through its existing pinned join machinery. It verifies the namespace,
genesis anchor, sole node instance, and sole active key before installing its
principal. Self-hosting is an ordinary signed transition in that identity
ontology. A hosting declaration confers no validator role: any membership
change still uses the existing target membership policy and consensus.

## Recovery

Yan selected strict no-resubmission for uncertain creation. Persist the exact
signed request and signature before dispatch through the existing local
identity pointer owner. After uncertainty or a crash, resolve that operation
and read its committed allocation. Absence, timeout, and signed-request expiry
are not proof that an already-custodied transaction cannot later commit.
An unresolved pre-admission request remains visible and unresolved. This
implementation defines no retry or custody-retirement procedure while its
outcome is unknown; automatic liveness across every crash is not promised.
A definite pre-execution ingress refusal (including admission or route
unavailability) or a completed failed proof is recorded durably before a later
readiness event may replace that request. Resolution of the exact winning
claim to an installed terminal rejection or atomic abort also permits that
transition. An unrelated refused attempt or an effect-journal error does not.
A crash before recording the refusal remains uncertain. The same custody
rule governs activation. No retry timer or elapsed expiry grants authority.

The pointer must distinguish an unfinished enrollment from a verified binding.
Malformed data, conflicting allocation, wrong key/anchor/instance, and missing
retained ledger fail closed. Restart and endpoint changes preserve the exact
reference. `node_enrollment` in namespace-manager statistics distinguishes
waiting, refused, unresolved, awaiting route/identity, complete, and errors.
A missing pointer with an existing allocation is an explicit data-loss error;
operator recovery must verify and bind that original reference using the
existing `quod_node_actor:bind/4` seam. A completed unchanged restart creates nothing and rewrites no
identity file. A restart with an allocation still awaiting activation reads
the pointer before root's storage is configured: the allocation stays pending,
the node starts, and enrollment resumes it once root is up. Readiness uses existing owner notifications and absolute
request deadlines; it does not authorize replay of an uncertain write.

## Advertisements

An enrolled node author may publish locally ready root/system copies using
the exact pinned root identity and committed system catalogue, plus ordinary
copies backed by its own exact discoverable hosting facts. Receivers verify
the node instance, active key, catalogue anchors, and ordinary hosting facts.
Root control membership is only needed for bootstrap publication. Enrollment
replaces the bootstrap author's set with an empty generation and publishes
the complete eligible set under the node author. Lost withdrawal messages and
already-installed revoked claims remain bounded by their existing leases.

Private rows are excluded from public generations. Discoverability is the
host's publication choice, not target-owner consent; stronger global
confidentiality needs an explicit target policy. Advertised roles remain
hints: target role, membership, and ACL checks still govern use.
Catalogue withdrawal removes shared system authority. A separately committed
ordinary hosting fact can still advertise the withdrawn history; a namespace
still catalogued under another anchor cannot advertise that conflicting history.

## Retained deployment

The class recipe and exact root delegation must be installed through
authorized actions or atomic source editing. Updating bundled seed files does
not update retained ontologies. Refounding, when explicitly authorized for a
deployment, creates new histories and requires new exact references; it is not
identity recovery. No reset occurs automatically, and neither refounding nor
absence licenses uncertain-write replay or an ACL bypass.

For a fresh network, found `quod:node` through the root action with its source,
the ontology predicate module, and `node_identity_template(Source)` containing
the reviewed `node_instance.pl` bytes. Then commit the exact class anchor in
root's `system_ontology(Namespace, Anchor)` catalogue and
`ontology_creation_policy/2`. No per-node hosting configuration is stored in root.

For retained state, first verify the current root/node anchors, administrator
and creator grants, founder's exact pointer and active key. Use the system
source editor's authorized atomic transaction to install the changed class
rules and template, and root's narrow creation entry. Record the existing
founder's verified reference as `node_identity_allocation(Key, Ref, Ref)` in
the class; delegate `ontology_hosting_policy(ClassNamespace, ClassAnchor)` in
that identity. Finally enable root's exact creation-policy delegation. None
of those writes are implied by loading bundled seed files. A root
administrator can edit governed source but is not thereby an ontology creator.

An applicant may remain an observer of its identity. Its signed methods are
proved and committed by that identity's committee, initially the creation
executor. This carries the existing ontology trust boundary: the committee
controls its certified history and native host proofs, and the applicant's
write liveness depends on it. Enrollment does not change committee governance
or claim protection against a malicious validator. A later committee change
must pass that ontology's explicit membership policy.
