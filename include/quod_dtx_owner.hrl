%% Keep each retained semantic control and its exact signed envelope once and
%% re-drive it; never copy it into the ordinary transaction custody queues.
%% Logical readiness, not a compiled population cap, controls scheduling.
-record(dtx_submission, {
    record :: quod_dtx:control_record(),
    control :: quod_dtx:control(),
    envelope :: binary(),
    group_id :: <<_:256>>,
    digest :: <<_:256>>,
    inserted_at :: integer(),
    observation_started_at :: integer(),
    %% Observation follows this existing volatile control row, never its
    %% signed envelope or journal. Recovered controls have no caller parent.
    trace_ctx = #{} :: quod_trace:context(),
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
