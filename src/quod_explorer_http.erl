-module(quod_explorer_http).
-moduledoc """
REST side of the explorer (`m:quod_explorer`): JSON reads over the durable ledger and
the running consensus/kb processes, plus the prove/submit endpoint.

| endpoint | answers |
| -------- | ------- |
| `GET /api/summary` | node identity + per-namespace consensus status (height, committee, finality head, next proposer…) |
| `GET /api/txs?ns=&before=&limit=` | transactions newest-first, paged back through the block log |
| `GET /api/tx/:ns/:id` | one transaction by id (bounded backward scan — no global tx index yet) |
| `GET /api/block/:ns/:slot` | one committed block, with its quorum certificate |
| `POST /api/prove` `{ns, goal}` | run a goal through `quod_prolog:prove/3` — a read answers with bindings; a write answers with its committed height or a pending transaction id if the local wait expires first |

History reads use the same pattern as `quod_catchup:serve_blocks/4`: a read-only
store view per request (`quod_ledger_store:open_ro/2`), never the writer's handle.
Term rendering is real Prolog text via `erlog_io:writeq1/1`; raw binaries inside
terms (pubkeys) are first rewritten to their printable short form. All JSON goes
through OTP's `m:json`.

This module also exports the shared JSON builders `m:quod_explorer_ws` reuses for
the live stream, so a transaction renders identically live and from history.
""".
-export([init/2]).
%% shared with quod_explorer_ws — one rendering of a transaction, live or historical
-export([summary/0, tx_json_full/2, entry_txs/1, cert_json/1, tx_id_text/1, encode/1]).
-ifdef(TEST).
-export([prolog_text/1, txs_page/3, find_tx/2, parse_goal/1,
         prove_result/1, committee_status_json/1]).   %% pure surface driven directly by eunit
-endif.
-include("quod_ledger.hrl").

-define(DEFAULT_PAGE, 25).
-define(MAX_PAGE, 100).
-define(SCAN_SLOTS, 1000).          %% max blocks walked per /api/txs page
-define(TX_SCAN_SLOTS, 5000).       %% max blocks walked hunting a tx id
-define(MAX_GOAL_BYTES, 4096).      %% /api/prove goal-text cap — a query is small; anything larger is refused
%% Parsing goal text mints atoms (erlog's scanner uses `list_to_atom`), so the write endpoint could exhaust
%% the VM atom table. `/api/prove` refuses once fewer than this many atoms remain, so it can degrade itself
%% but never crash the node. (Defence in depth on top of the small goal cap and the opt-in/loopback bind.)
-define(ATOM_SAFETY_MARGIN, 100000).

%%%===================================================================
%%% cowboy handler
%%%===================================================================

init(Req0, health) ->
    {ok, cowboy_req:reply(200, #{<<"content-type">> => <<"text/plain">>}, <<"ok\n">>, Req0), health};
init(Req0, Op) ->
    Req = try handle(Op, Req0)
          catch Class:Reason:Stack ->
                    logger:warning("quod explorer: ~p failed ~p:~p ~p", [Op, Class, Reason, Stack]),
                    json_reply(500, #{error => internal}, Req0)
          end,
    {ok, Req, Op}.

handle(summary, Req) ->
    json_reply(200, summary(), Req);
handle(txs, Req) ->
    Qs = maps:from_list(cowboy_req:parse_qs(Req)),
    %% A valueless query key (`?ns`, `?limit`) parses to the atom `true`; treat any non-binary value as
    %% absent so a bare `?ns` is a clean `missing_ns` and a bare `?limit`/`?before` falls to its default
    %% (rather than reaching int_param as `true` and function_clause-crashing to a 500).
    case bin_param(maps:get(<<"ns">>, Qs, undefined)) of
        undefined -> json_reply(400, #{error => missing_ns}, Req);
        Ns ->
            Before = int_param(maps:get(<<"before">>, Qs, undefined), undefined),
            Limit  = min(?MAX_PAGE, int_param(maps:get(<<"limit">>, Qs, undefined), ?DEFAULT_PAGE)),
            json_reply(200, with_store(Ns, fun(Store) -> txs_page(Store, Before, Limit) end,
                                       #{txs => [], height => 0, next_before => null}), Req)
    end;
handle(tx, Req) ->
    Ns = cowboy_req:binding(ns, Req),
    Id = cowboy_req:binding(id, Req),
    case with_store(Ns, fun(Store) -> find_tx(Store, Id) end, not_found) of
        not_found -> json_reply(404, #{error => not_found}, Req);
        Found     -> json_reply(200, Found, Req)
    end;
handle(block, Req) ->
    Ns = cowboy_req:binding(ns, Req),
    case int_param(cowboy_req:binding(slot, Req), undefined) of
        undefined -> json_reply(400, #{error => bad_slot}, Req);
        Slot ->
            R = with_store(Ns, fun(Store) ->
                    case quod_ledger_store:read_at(Store, Slot) of
                        {ok, E}   -> block_json(E);
                        not_found -> not_found
                    end
                end, not_found),
            case R of
                not_found -> json_reply(404, #{error => not_found}, Req);
                Block     -> json_reply(200, Block, Req)
            end
    end;
handle(prove, Req0) ->
    case cowboy_req:method(Req0) of
        <<"POST">> ->
            %% A body over the cap returns `{more, _, _}`; refuse it as too-large (413) instead of
            %% badmatching to a 500 — and never buffer more than one extra chunk of it.
            case cowboy_req:read_body(Req0, #{length => ?MAX_GOAL_BYTES}) of
                {ok, Body, Req} ->
                    Decoded = try json:decode(Body) catch _:_ -> bad_json end,
                    prove(Decoded, Req);
                {more, _Partial, Req} ->
                    json_reply(413, #{error => body_too_large}, Req)
            end;
        _ ->
            json_reply(405, #{error => method_not_allowed}, Req0)
    end.

%%%===================================================================
%%% prove — the submit console
%%%===================================================================

prove(#{<<"ns">> := Ns, <<"goal">> := Text}, Req)
  when is_binary(Ns), is_binary(Text), byte_size(Text) =< ?MAX_GOAL_BYTES ->
    quod_trace:with_span(
      quod_trace:extract(trace_headers(Req)), <<"quod.http.prove">>, server,
      #{'quod.namespace' => Ns, 'quod.goal.bytes' => byte_size(Text),
        'http.request.method' => <<"POST">>, 'url.path' => <<"/api/prove">>},
      fun(SpanCtx) ->
          case atom_headroom_ok() of
              false ->
                  _ = quod_trace:result(SpanCtx, {error, atom_table_pressure}),
                  json_reply(503, #{error => atom_table_pressure}, Req);
              true ->
                  case parse_goal(Text) of
                      {ok, Goal} ->
                          Result = quod_prolog:prove(Ns, Goal, Ns),
                          _ = quod_trace:result(SpanCtx, Result),
                          {Code, Reply} = prove_result(Result),
                          json_reply(Code, Reply, Req);
                      {error, Detail} ->
                          _ = quod_trace:result(SpanCtx, {error, parse_error}),
                          json_reply(400, #{error => parse_error, detail => Detail}, Req)
                  end
          end
      end);
prove(#{<<"goal">> := Text}, Req) when is_binary(Text), byte_size(Text) > ?MAX_GOAL_BYTES ->
    json_reply(413, #{error => goal_too_large}, Req);
prove(_Bad, Req) ->
    json_reply(400, #{error => bad_request}, Req).

%% Parsing goal text mints atoms; refuse before doing so if too few atoms remain, so `/api/prove` can
%% never exhaust the table and crash the VM (it just stops serving until the node is restarted).
atom_headroom_ok() ->
    erlang:system_info(atom_count) + ?ATOM_SAFETY_MARGIN < erlang:system_info(atom_limit).

trace_headers(Req) ->
    [{Name, Value}
     || Name <- [<<"traceparent">>, <<"tracestate">>],
        Value <- [cowboy_req:header(Name, Req, undefined)],
        is_binary(Value)].

%% Goal text is one Prolog term; the parser requires the closing `.`, so add it when the
%% console user (reasonably) left it off.
parse_goal(Text) ->
    S0 = string:trim(unicode:characters_to_list(Text)),
    S = case lists:suffix(".", S0) of true -> S0; false -> S0 ++ " ." end,
    case erlog_io:read_string(S) of
        {ok, Goal}           -> {ok, Goal};
        {error, {_L, _M, E}} -> {error, text(E)}
    end.

prove_result({ok, Bindings, Height}) ->
    {200, #{result => ok, height => Height, bindings => [bindings_json(B) || B <- Bindings]}};
prove_result(fail) ->
    {200, #{result => fail}};
prove_result({error, {not_leader, Hint}}) ->
    Leader = case Hint of none -> null; _ -> id_json(Hint) end,
    {409, #{error => not_leader, leader => Leader}};
prove_result({error, {outcome_unknown, TxId}}) when is_binary(TxId) ->
    {202, #{result => pending, tx_id => tx_id_text(TxId)}};
prove_result({error, Reason}) ->
    {503, #{error => text(Reason)}}.

bindings_json(B) when is_map(B) ->
    maps:fold(fun(V, T, Acc) -> Acc#{atom_to_binary(V, utf8) => prolog_text(T)} end, #{}, B);
bindings_json(Other) ->
    #{<<"value">> => prolog_text(Other)}.

%%%===================================================================
%%% summary
%%%===================================================================

-doc "Node identity + per-namespace consensus status. Shared with the WS `hello` frame.".
summary() ->
    Node = case application:get_env(quod, node_pubkey) of
               {ok, P} when is_binary(P) -> id_json(P);
               _ -> null
           end,
    #{node => Node,
      namespaces => [ns_summary(Ns) || Ns <- lists:sort(quod_simplex:namespaces())]}.

ns_summary(Ns) ->
    St = quod_simplex:status(Ns),
    Committee = quod_simplex:committee(Ns),
    Slot = maps:get(slot, St, 0),
    Approved = maps:get(approved, St, Slot),
    FinalitySlot = maps:get(finality_slot, St, Slot + 1),
    ProposalSlot = maps:get(proposal_slot, St, Approved + 1),
    maps:merge(
      #{ns        => Ns,
        height    => maps:get(committed, St, 0),
        applied   => quod_prolog:applied(Ns),
        role      => maps:get(role, St, observer),
        syncing   => maps:get(syncing, St, false),
        committee => [id_json(M) || M <- Committee],
        approved  => Approved,
        finality_slot => FinalitySlot,
        finality_leader => leader_json(FinalitySlot, Committee),
        proposal_slot => ProposalSlot,
        next_proposer => leader_json(ProposalSlot, Committee),
        proposal_open => maps:get(proposal_open, St, false),
        progress_phase => maps:get(progress_phase, St, idle),
        progress_quorum_ready => maps:get(progress_quorum_ready, St, false),
        genesis   => case quod_simplex:genesis_hash(Ns) of
                         H when is_binary(H) -> binary:encode_hex(H, lowercase);
                         _ -> null
                     end},
      committee_status_json(St)).

%% Invalid/missing committee identity is exposed as `null`, so a fleet
%% preflight fails closed instead of benchmarking divergent committee views.
committee_status_json(St) ->
    #{committee_id =>
          case maps:get(committee_id, St, undefined) of
              Id when is_binary(Id), byte_size(Id) =:= 32 ->
                  binary:encode_hex(Id, lowercase);
              _ ->
                  null
          end}.

leader_json(Slot, Committee) when is_integer(Slot), Slot >= 1 ->
    case quod_simplex:leader(Slot, Committee) of
        L when is_binary(L); is_tuple(L) -> id_json(L);
        _ -> null
    end;
leader_json(_Slot, _Committee) ->
    null.

%%%===================================================================
%%% history — read-only ledger views (quod_catchup's pattern)
%%%===================================================================

with_store(Ns, Fun, Empty) ->
    Dirs = application:get_env(quod, content_data_dirs, #{}),
    Dir = maps:get(Ns, Dirs, quod_ledger_store:default_data_dir()),
    case quod_ledger_store:open_ro(Ns, Dir) of
        {ok, Store} ->
            try Fun(Store) after quod_ledger_store:close(Store) end;
        {error, _} ->
            Empty
    end.

txs_page(Store, Before, Limit) ->
    Last = quod_ledger_store:last(Store),
    From = case Before of undefined -> Last; B -> min(B - 1, Last) end,
    {Txs, NextBefore} = collect_txs(Store, From, Limit, ?SCAN_SLOTS, []),
    #{txs => Txs, height => Last, next_before => NextBefore}.

%% Walk slots downward until `Need` transaction rows are collected or the scan budget is
%% spent; newest first. `NextBefore` is the `before` for the next page (`null` = at genesis).
collect_txs(_Store, Slot, _Need, _Scan, Acc) when Slot < 1 ->
    {Acc, null};
collect_txs(_Store, Slot, Need, Scan, Acc) when Need =< 0; Scan =< 0 ->
    {Acc, Slot + 1};
collect_txs(Store, Slot, Need, Scan, Acc) ->
    case quod_ledger_store:read_at(Store, Slot) of
        {ok, E} ->
            Rows = [tx_json(T, E) || T <- entry_txs(E)],
            collect_txs(Store, Slot - 1, Need - length(Rows), Scan - 1, Acc ++ Rows);
        not_found ->
            collect_txs(Store, Slot - 1, Need, Scan - 1, Acc)
    end.

%% Bounded backward hunt for a tx id (hex as listed, or the raw genesis id text).
%% No global tx index exists yet — the reader-arc (doc/deferred.md §4) is the real fix.
find_tx(Store, Id) ->
    find_tx(Store, quod_ledger_store:last(Store), Id, ?TX_SCAN_SLOTS).

find_tx(_Store, Slot, _Id, Scan) when Slot < 1; Scan =< 0 ->
    not_found;
find_tx(Store, Slot, Id, Scan) ->
    case quod_ledger_store:read_at(Store, Slot) of
        {ok, E} ->
            case [T || T <- entry_txs(E), tx_id_text(T#transaction.tx_id) =:= Id] of
                [T | _] -> #{tx => tx_json_full(T, E), block => block_meta(E)};
                []      -> find_tx(Store, Slot - 1, Id, Scan - 1)
            end;
        not_found ->
            find_tx(Store, Slot - 1, Id, Scan - 1)
    end.

entry_txs(#entry{data = Data}) ->
    case quod_ledger:payload(Data) of
        {ok, Txs} -> Txs;
        error     -> []          %% noop skip-slot
    end.

%%%===================================================================
%%% JSON builders (shared with quod_explorer_ws)
%%%===================================================================

-doc "The list-row rendering of one transaction inside its committed entry.".
tx_json(#transaction{tx_id = Id, caller_ns = CNs, goal = G, author = A,
                     author_seq = AuthorSeq, submitted_at = Sub, diff = Diff},
        #entry{index = Slot, timestamp = Ts}) ->
    #{tx_id => tx_id_text(Id), ns => CNs, height => Slot, time => Ts,
      goal => goal_text(G), author => id_json(A), author_seq => AuthorSeq,
      submitted_at => Sub,
      ops => length(Diff)}.

-doc "The detail rendering: the row plus result bindings, authentication, the diff, and OCC extent.".
tx_json_full(#transaction{result = Res, diff = Diff, read_check = RC, sig = Sig} = T, E) ->
    (tx_json(T, E))#{result => result_json(Res),
                     diff => [op_json(Op) || Op <- Diff],
                     read_predicates => map_size(RC),
                     signature => signature_json(Sig),
                     signature_status => signature_status(T, E)}.

signature_json(Sig) when is_binary(Sig) -> binary:encode_hex(Sig, lowercase);
signature_json(none) -> null.

signature_status(#transaction{sig = none}, #entry{index = 1}) -> genesis;
signature_status(#transaction{sig = none}, _Entry) -> unsigned;
signature_status(#transaction{sig = Sig}, _Entry)
  when is_binary(Sig), byte_size(Sig) =:= 64 ->
    verified;
signature_status(_Transaction, _Entry) ->
    invalid.

block_json(#entry{index = Slot} = E) ->
    (block_meta(E))#{txs => [tx_json_full(T, E) || T <- entry_txs(E)],
                     slot => Slot}.

block_meta(#entry{index = Slot, data = Data, timestamp = Ts, cert = Cert}) ->
    #{slot => Slot, time => Ts, noop => Data =:= noop, cert => cert_json(Cert)}.

cert_json(none) -> null;
cert_json(#cert{kind = K, sigs = Sigs}) ->
    #{kind => K, signers => [id_json(P) || {P, _Sig} <- Sigs]};
cert_json(#implicit_cert{child = Child, commit = Commit}) ->
    %% committed implicitly by its child (depth-1 pipelining) — show the child's commit quorum
    #{kind => implicit, child_slot => Child#block.slot,
      signers => [id_json(P) || {P, _Sig} <- Commit#cert.sigs]}.

result_json(undefined) -> null;
result_json(B) when is_map(B) -> bindings_json(B);
result_json(L) when is_list(L) -> [bindings_json(B) || B <- L];
result_json(Other) -> prolog_text(Other).

op_json({assert, Clause})  -> #{op => assert,  clause => clause_text(Clause)};
op_json({retract, Clause}) -> #{op => retract, clause => clause_text(Clause)}.

%% A stored clause body is erlog's COMPILED `{Goals, HasCut}` form (`well_form_body`): a plain
%% fact compiles to `{[], _}` and renders as its head alone; a rule's goal list renders as the
%% familiar comma body.
clause_text({Head, true}) -> prolog_text(Head);
clause_text({Head, {[], _HasCut}}) -> prolog_text(Head);
clause_text({Head, {Goals, _HasCut}}) when is_list(Goals) ->
    unicode:characters_to_binary(
      [prolog_text(Head), " :- ", lists:join(", ", [prolog_text(G) || G <- Goals])]);
clause_text({Head, Body}) -> <<(prolog_text(Head))/binary, " :- ", (prolog_text(Body))/binary>>.

goal_text(undefined) -> null;
goal_text(G)         -> prolog_text(G).

%% A transaction id is opaque bytes. Show printable values as-is and encode
%% binary protocol ids (including the versioned genesis id) as hexadecimal.
tx_id_text(Id) when is_binary(Id) ->
    case printable(Id) of
        true  -> Id;
        false -> binary:encode_hex(Id, lowercase)
    end.

id_json(Pk) when is_binary(Pk) ->
    #{id => quod_identity:short(Pk), pubkey => binary:encode_hex(Pk, lowercase)};
id_json({Pk, _Host, _Port}) when is_binary(Pk) ->
    id_json(Pk);
id_json({Host, Port}) ->      %% configuration-free test node id
    #{id => iolist_to_binary([text(Host), ":", integer_to_binary(Port)]), pubkey => null};
id_json(undefined) ->
    null.

-doc """
Render an erlog term as *display* Prolog text. `erlog_io:writeq1/1` on its own prints strings and
binaries as byte lists (`"10.0.0.1"` → `[49,48,…]`), unreadable in a UI. erlog has no callback for
per-leaf rendering and no string type, so `pt/2` reproduces `erlog_io:write_term1/3`'s operator
precedence/paren layout (reusing `m:erlog_parse`'s op tables) around leaf kinds erlog can't show:
printable charlists as escaped `"strings"`, 32-byte binaries as their `kp_…` short id (the house
convention — content 32-byte binaries are Ed25519 pubkeys, e.g. `peer_admitted` args), and other
binaries as escaped `<<"text">>` / truncated `<<0xhex…>>`. Display-only — never parsed back, never
mints atoms.
""".
prolog_text(T) ->
    unicode:characters_to_binary(pt(T, 1200)).

pt(A, _) when is_atom(A) -> erlog_io:writeq1(A);
pt(N, _) when is_number(N) -> io_lib:write(N);
pt(B, _) when is_binary(B), byte_size(B) =:= 32 ->
    binary_to_list(quod_identity:short(B));            %% an Ed25519 pubkey, by convention
pt(B, _) when is_binary(B) ->
    case printable(B) of
        true  -> [<<"<<\"">>, [escape(C) || C <- unicode:characters_to_list(B)], <<"\">>">>];
        false -> [<<"<<0x">>, binary:encode_hex(binary:part(B, 0, min(16, byte_size(B))), lowercase),
                  case byte_size(B) > 16 of true -> <<"…>>">>; false -> <<">>">> end]
    end;
pt({V}, _) when is_integer(V) -> [$_ | integer_to_list(V)];   %% erlog variable
pt({V}, _) when is_atom(V) -> atom_to_list(V);
pt([], _) -> "[]";
pt(L, _) when is_list(L) ->
    case io_lib:printable_unicode_list(L) of
        true  -> [$", [escape(C) || C <- L], $"];      %% a Prolog string IS a charlist
        false -> [$[, lists:join(", ", [pt(E, 999) || E <- proper(L)]), $]]
    end;
pt({F, A}, Prec) when is_atom(F) ->
    case erlog_parse:prefix_op(F) of
        {yes, OpP, ArgP} -> parens([erlog_io:writeq1(F), $\s, pt(A, ArgP)], OpP, Prec);
        no -> [erlog_io:writeq1(F), $(, pt(A, 999), $)]
    end;
pt({',', A, B}, Prec) ->
    parens([pt(A, 999), ", ", pt(B, 1000)], 1000, Prec);
pt({F, A, B}, Prec) when is_atom(F) ->
    case erlog_parse:infix_op(F) of
        {yes, Lp, OpP, Rp} -> parens([pt(A, Lp), op_pad(F), pt(B, Rp)], OpP, Prec);
        no -> [erlog_io:writeq1(F), $(, pt(A, 999), $,, $\s, pt(B, 999), $)]
    end;
pt(T, _) when is_tuple(T), tuple_size(T) > 1, is_atom(element(1, T)) ->
    [F | Args] = tuple_to_list(T),
    [erlog_io:writeq1(F), $(, lists:join(", ", [pt(A, 999) || A <- Args]), $)];
pt(T, _) ->
    io_lib:write(T).

%% `:`/`::` names read as one token (`quod:animal`); every other operator breathes.
op_pad(F) when F =:= ':'; F =:= '::' -> atom_to_list(F);
op_pad(F) -> [$\s, atom_to_list(F), $\s].

parens(Out, OpP, Prec) when OpP > Prec -> [$(, Out, $)];
parens(Out, _OpP, _Prec) -> Out.

escape($") -> "\\\"";
escape($\\) -> "\\\\";
escape(C) -> C.

%% An improper tail still renders rather than crashing the page.
proper([H | T]) when is_list(T) -> [H | proper(T)];
proper([H | T]) -> [H, T];
proper([]) -> [].

printable(B) ->
    case unicode:characters_to_list(B) of
        L when is_list(L) -> io_lib:printable_unicode_list(L);
        _ -> false
    end.

%%%===================================================================
%%% plumbing
%%%===================================================================

encode(Json) -> iolist_to_binary(json:encode(Json)).

json_reply(Code, Json, Req) ->
    cowboy_req:reply(Code, #{<<"content-type">> => <<"application/json">>}, encode(Json), Req).

%% A present query value is a binary; a valueless key is the atom `true`. Normalise anything non-binary
%% to `undefined` so callers see "absent".
bin_param(B) when is_binary(B) -> B;
bin_param(_)                   -> undefined.

int_param(Bin, Default) when is_binary(Bin) ->
    case string:to_integer(binary_to_list(Bin)) of
        {I, ""} when I >= 0 -> I;
        _ -> Default
    end;
int_param(_NotBinary, Default) -> Default.

text(T) when is_binary(T) -> T;
text(T) when is_atom(T) -> atom_to_binary(T, utf8);
text(T) when is_list(T) ->
    case unicode:characters_to_binary(T) of
        B when is_binary(B) -> B;
        _ -> iolist_to_binary(io_lib:format("~0p", [T]))
    end;
text(T) -> iolist_to_binary(io_lib:format("~0p", [T])).
