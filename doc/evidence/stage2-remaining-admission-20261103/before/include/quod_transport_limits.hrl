-ifndef(QUOD_TRANSPORT_LIMITS_HRL).
-define(QUOD_TRANSPORT_LIMITS_HRL, true).

%% quod_link's payload length is an unsigned 32-bit field. This is the
%% representable frame capacity, not an allocation or ingress quota.
-define(QUOD_LINK_PAYLOAD_BITS, 32).
-define(QUOD_LINK_PAYLOAD_CAPACITY, ((1 bsl ?QUOD_LINK_PAYLOAD_BITS) - 1)).
%% Retained history-page admission policy; not the actual transport capacity.
-define(QUOD_MAX_FOREIGN_PAGE_BYTES, (900 * 1024)).

-endif.
