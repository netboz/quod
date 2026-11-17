%% Historical regression inputs, not runtime allocation policy.
%% Values at the saved admission baseline; production has no dependency here.
-ifndef(RETIRED_PRESENTATION_SIZES_HRL).
-define(RETIRED_PRESENTATION_SIZES_HRL, true).
-define(LEGACY_MAX_PLAN_ENVELOPE_BYTES, 424064).
-define(LEGACY_MAX_DURABLE_RESULT_BYTES, 16384).
-define(LEGACY_MAX_DTX_BODY_BYTES, 424064).
-define(LEGACY_MAX_DTX_CONTROL_BYTES, 456804).
-define(LEGACY_SCOPE_WIRE_MAX_ENVELOPE_BYTES, 1012977).
-define(LEGACY_DTX_BATCH_PAYLOAD_OVERHEAD_BYTES, 28).
-endif.
