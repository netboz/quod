%% Keep each retained semantic control and its exact signed envelope once and
%% re-drive it; never copy it into the ordinary transaction custody queues.
%% Logical readiness, not a compiled population cap, controls scheduling.
%% The control already carries its authenticated material. Never retain a
%% second plan/material field; the journal retains only the canonical bytes.
-record(dtx_submission, {
    control :: quod_atomic:control(),
    envelope :: binary(),
    group_id :: <<_:256>>,
    digest :: <<_:256>>,
    inserted_at :: integer(),
    observation_started_at :: integer(),
    %% Observation follows this existing volatile control row, never its
    %% signed envelope or journal. Recovered controls have no caller parent.
    trace_ctx = #{} :: quod_trace:context(),
    %% The local vote's cached parent/deadline selection. It is volatile,
    %% never a signature or a journal field; restart selects again. Relayed
    %% controls have no local selection and retain their author's envelope.
    selection = none :: none | term(),
    validation_sidecar = [] :: [quod_dtx_endpoint:validation_item()],
    placement :: ready | blocked,
    %% Volatile placement on the existing consensus link.  The retained row
    %% remains the sole custody owner; this marker only prevents unrelated
    %% mailbox traffic from enqueueing the same reliable relay repeatedly.
    %% A replacement link has a different pid and therefore re-drives it.
    relay_placement = none :: none | {binary(), pid()},
    bytes :: non_neg_integer(),
    waiters = #{} :: #{pid() => true}
}).
