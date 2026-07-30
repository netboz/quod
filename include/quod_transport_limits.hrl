-ifndef(QUOD_TRANSPORT_LIMITS_HRL).
-define(QUOD_TRANSPORT_LIMITS_HRL, true).

%% The largest payload carried by one quod_link frame.  Producers must stay
%% within this limit and consumers must reject larger payloads before decoding.
-define(QUOD_TRANSPORT_MAX_FRAME_BYTES, (1 bsl 20)).

-endif.
