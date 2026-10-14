# Remaining existing-owner integration contract

Yan requested autonomous implementation and Fable review, with no new GUI
execution path, no shadow queue, no uncertain-write resubmission, no transaction
splitting. Current explicit transitions, human HUD reads and portable common
renderers are implemented and scoped tests pass. Opening and automatic
continuation remain disabled. This packet requests architecture review of the
remaining concrete gaps, not another review of those delivered slices.

Read AGENTS.md and current specs. Frozen relevant owners are in tree/; other
existing owners may be read live, read-only if needed. No commands, tests or
production edits. Write fable-review.md here. Independently challenge the
following trace and identify a concrete executable extension through an existing
owner if one is justified. Do not weaken settled semantics or propose a new
process, cap increase, offline placeholder, broad GUI database or queue.

## Hosted-agent custody

quod_agent:start_request allocates an operation ID in transient state before
sign_request/4 builds the exact signed bytes. It retains no durable original
bytes before ingress. complete/4 sends agent_completed before agent_owned_result;
the runtime work cursor advances regardless of result. A changed dependency or
new incarnation permits another pass. FIPA explicitly opts into distinct attempts
despite earlier unknown; GUI must not inherit that policy.

The runtime asks Simplex for prior custody once per incarnation, then notices
shrink that set. This does not by itself cover pre-seal requests or preserve a
queryable original signed request for the agent. Absence from that snapshot is
not proof of a terminal failure. Node key vault owns keys, not signed requests;
the direct-effect journal explicitly is not an agent outbox.

The existing custodied request mode signs completion, commits a separate Prolog
custody template, then submits completion only after certified custody commit.
prepare_signed_request/3 is currently limited to physics reaction metadata.
Blind generalization is insufficient: an uncertain custody-store write can be
lost from transient work, and a crash after storage but before dispatch leaves
an original request whose missing outcome is not a rejection. A new signed
custody-store attempt cannot simply be assumed safe. Do not hide that operation
or its failure under a GUI status fact. Consider this existing mode only if its
whole original-operation ownership can be traced without uncertain resubmission.

Question: is there an existing durable original-request owner/seam the parent
has missed, or is extending the common agent/ingress custody contract necessary?
If an extension is necessary, name the exact owner, retained data and lifecycle
(before dispatch, terminal evidence, crash, host change, unchanged repeat cost),
without implementing a second work queue. A concrete counterexample to an
otherwise plausible path is more useful than a general recommendation.

## Live opening

Section5 of the frozen plan selects a genuine prepared presentation through
the existing action/effect journal. Its effect-only scope and source/responder/
human material scopes commit in one original atomic request. Preparation must
obtain actual authenticated client acceptance and installed authorized agent
feasibility; absence/refusal is Prolog failure. Disconnect after acceptance does
not cancel a committed question; expired release is terminal and HUD owns later
discovery.

Ordinary :: selects a validator, not an arbitrary client or agent host. The
node instance ontology may be founded remotely or locally only as observer;
join_ontology is owned by quod:node class. A receiver-host scope pin cannot be
assumed executable. The current websocket owner is space/physics-specific.
Remote preparation must use an existing transport/resource owner and retain
authority through activation; trusting a caller-supplied receiver string or a
peer claiming commit is insufficient. No second presentation engine is allowed.

Identify the smallest concrete owner extension for authenticated receiver
selection, private provisional preparation, original-request binding and
certified release, or state precisely which missing contract prevents a safe
implementation. Do not reopen the settled absent-human/agent failure behavior.
