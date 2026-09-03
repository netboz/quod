-ifndef(QUOD_TERM_LIMITS_HRL).
-define(QUOD_TERM_LIMITS_HRL, true).

%% One structural-depth boundary for untrusted Prolog and ETF values. Lists
%% are traversed iteratively; their elements and improper tail count as nested.
-define(QUOD_MAX_TERM_DEPTH, 64).

-endif.
