-module(quod_resolve_tests).
-include_lib("eunit/include/eunit.hrl").

%% The transport resolver: a pubkey resolves to a learned endpoint; an endpoint dials
%% direct; an unknown pubkey / bad target is a miss. (quod_quic:learn/2 + resolve/1 work
%% on a public named ETS.) Since DA#1, `store_hint` no longer CREATES the cache — only
%% quod_quic:init does, so a hint written from a foreign process can't own a table that
%% dies with it; each test creates the cache itself via the TEST-only ensure_cache/0.

cache() -> _ = quod_quic:ensure_cache(), ok.

resolve_endpoint_direct_test() ->
    ?assertEqual({ok, {"h", 5}}, quod_quic:resolve({"h", 5})),
    ?assertEqual({ok, {<<"h">>, 14567}}, quod_quic:resolve({<<"h">>, 14567})),
    ?assertEqual(error, quod_quic:resolve({"h", 0})),        %% port out of range
    ?assertEqual(error, quod_quic:resolve({"h", 70000})),
    ?assertEqual(error, quod_quic:resolve(an_atom)).

learn_then_resolve_test() ->
    cache(),
    PK = crypto:strong_rand_bytes(32),
    ?assertEqual(error, quod_quic:resolve(PK)),              %% unknown pubkey ⇒ miss
    ok = quod_quic:learn(PK, {"10.0.0.1", 14567}),
    ?assertEqual({ok, {"10.0.0.1", 14567}}, quod_quic:resolve(PK)),
    %% re-learning OVERWRITES the hint (a moved peer / fresh live evidence)
    ok = quod_quic:learn(PK, {"10.0.0.9", 14567}),
    ?assertEqual({ok, {"10.0.0.9", 14567}}, quod_quic:resolve(PK)).

learn_ignores_non_pubkey_test() ->
    %% a non-binary id has nothing to resolve; learn is a no-op, resolve is a miss
    ?assertEqual(ok, quod_quic:learn({"h", 1}, {"h", 1})),
    ?assertEqual(error, quod_quic:resolve(<<"short">>)).     %% binary but not learned

%% learn_if_absent fills a VOID but never CLOBBERS a live hint (a historical replayed address must not
%% overwrite what a header already taught) — the Slice-D catch-up hook's polarity.
learn_if_absent_fills_void_then_preserves_test() ->
    cache(),
    PK = crypto:strong_rand_bytes(32),
    ok = quod_quic:learn_if_absent(PK, {"10.0.0.1", 14567}),  %% no hint yet ⇒ fills it
    ?assertEqual({ok, {"10.0.0.1", 14567}}, quod_quic:resolve(PK)),
    ok = quod_quic:learn_if_absent(PK, {"10.0.0.9", 14567}),  %% already present ⇒ IGNORED (stale/historical)
    ?assertEqual({ok, {"10.0.0.1", 14567}}, quod_quic:resolve(PK)),
    ok = quod_quic:learn(PK, {"10.0.0.9", 14567}),            %% but LIVE evidence still overwrites
    ?assertEqual({ok, {"10.0.0.9", 14567}}, quod_quic:resolve(PK)).

%% [DA#1] a hint written before the cache exists (transport down / mid-restart) is a fail-closed
%% no-op, never a crash — store_hint catches the badarg from a missing table.
store_hint_no_table_is_noop_test() ->
    catch ets:delete(quod_addr_cache),
    PK = crypto:strong_rand_bytes(32),
    ?assertEqual(ok, quod_quic:learn(PK, {"10.0.0.1", 14567})),
    ?assertEqual(ok, quod_quic:learn_if_absent(PK, {"10.0.0.1", 14567})),
    ?assertEqual(error, quod_quic:resolve(PK)).              %% nothing stored ⇒ miss
