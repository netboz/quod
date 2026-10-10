-ifndef(QUOD_C4_ATTEMPT_HRL).
-define(QUOD_C4_ATTEMPT_HRL, true).
-ifdef(QUOD_C4_PHASE1).
-define(C4_ATTEMPT(Ctx, Tracer, Name, Attributes, Operation),
        quod_c4_attempt:allocate_span(Ctx, Tracer, Name, Attributes, Operation)).
-else.
-define(C4_ATTEMPT(Ctx, Tracer, Name, Attributes, Operation), (Operation)()).
-endif.
-endif.
