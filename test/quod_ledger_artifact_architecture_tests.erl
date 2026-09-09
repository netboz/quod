-module(quod_ledger_artifact_architecture_tests).
-include_lib("eunit/include/eunit.hrl").

%% An opaque type is not proof against hostile code in this VM. This guard
%% instead closes the reviewed production dataflow: one private representation,
%% one mint, named checked constructors/byte ingresses, and the ordinary store
%% append sites. Accessors confer no new authority and are deliberately absent.
production_artifact_inventory_test() ->
    Root = source_root(),
    Files = lists:sort(filelib:fold_files(filename:join(Root, "src"), "\\.erl$", true,
                                        fun(F, Acc) -> [F | Acc] end, [])),
    ?assert(Files =/= []),
    Forms = [production_forms(File, Root) || File <- Files],
    Declarations = lists:append([declarations(F) || F <- Forms]),
    ?assertEqual([{quod_ledger, [bytes, view, block]}], Declarations),
    Inventory = lists:append([inventory(F) || F <- Forms]),
    ?assertEqual(lists:sort(reviewed_sites()), lists:sort(Inventory)),
    %% The only mint is private even though all production call sites are also
    %% pinned below. A new public unchecked constructor is a review failure.
    [Ledger] = [F || F <- Forms, module(F) =:= quod_ledger],
    Exports = lists:append([E || {attribute, _, export, E} <- Ledger]),
    ?assertNot(lists:member({mint_artifact, 3}, Exports)),
    ?assertNot(lists:member({encode_entry_view, 2}, Exports)).

reviewed_sites() ->
    [%% Byte ingress: each framed page/feed/sidecar or on-disk frame reaches
     %% the same codec once. The public /1 delegation selects its old mode.
     {{quod_catchup, decode_entry_blobs, 3}, {call, quod_ledger, decode_entry, 2}},
     {{quod_dtx_endpoint, decode_sidecar, 2}, {call, quod_ledger, decode_entry, 2}},
     {{quod_feed, decode_inner, 1}, {call, quod_ledger, decode_entry, 1}},
     {{quod_ledger_store, fold_run, 7}, {call, quod_ledger, decode_entry, 2}},
     {{quod_ledger_store, scan, 9}, {call, quod_ledger, decode_entry, 2}},
     {{quod_ledger, decode_entry, 1}, {call, quod_ledger, decode_entry, 2}},
     %% The decoder's two arms and checked native constructor share one mint.
     {{quod_ledger, decode_entry, 2}, {call, quod_ledger, mint_artifact, 3}},
     {{quod_ledger, decode_entry, 2}, {call, quod_ledger, mint_artifact, 3}},
     {{quod_ledger, encode_entry_view, 2}, {call, quod_ledger, mint_artifact, 3}},
     {{quod_ledger, entry, 2}, {call, quod_ledger, encode_entry_view, 2}},
     {{quod_ledger, new_entry, 4}, {call, quod_ledger, encode_entry_view, 2}},
     {{quod_ledger, new_entry, 4}, {call, quod_ledger, encode_entry_view, 2}},
     {{quod_ledger, noop_entry, 2}, {call, quod_ledger, encode_entry_view, 2}},
     {{quod_ledger, from_entry_view, 1}, {call, quod_ledger, encode_entry_view, 2}},
     {{quod_ledger, from_entry_view, 1}, {call, quod_ledger, encode_entry_view, 2}},
     {{quod_ledger, mint_artifact, 3}, artifact_record},
     %% These are the three read-only destructuring sites, not constructors.
     {{quod_ledger, block_from_entry, 1}, artifact_record},
     {{quod_ledger, encode_entry, 1}, artifact_record},
     {{quod_ledger, entry_view, 1}, artifact_record},
     %% Local consensus and prepared-genesis import remain the only native
     %% production construction origins; no raw record append is allowed.
     {{quod_simplex, commit_block, 3}, {call, quod_ledger, entry, 2}},
     {{quod_simplex, prepare_genesis, 3}, {call, quod_ledger, entry, 2}},
     {{quod_simplex, skip_block, 2}, {call, quod_ledger, noop_entry, 2}},
     {{quod_simplex, genesis_entry, 2}, {call, quod_ledger, from_entry_view, 1}},
     %% Local and foreign installation all use the sole store append API.
     {{quod_simplex, append_genesis, 2}, {call, quod_ledger_store, append, 2}},
     {{quod_simplex, persist_entry, 4}, {call, quod_ledger_store, append, 2}},
     {{quod_simplex, apply_catchup_window, 4}, {call, quod_ledger_store, append, 2}},
     {{quod_foreign_log, persist_verified_page, 8}, {call, quod_ledger_store, append, 2}},
     %% The existing predicate registry is the sole unresolved dynamic MFA.
     {{quod_predicates, dispatch, 3}, dynamic_dispatch}].

source_root() ->
    Source = proplists:get_value(source, ?MODULE:module_info(compile)),
    filename:dirname(filename:dirname(filename:absname(Source))).

production_forms(File, Root) ->
    {ok, Forms} = epp:parse_file(File, [filename:join(Root, "include")], []),
    %% Expand without TEST and fail closed on every preprocessing error.
    ?assertEqual({File, []}, {File, [E || {error, E} <- Forms]}),
    Forms.

module(Forms) ->
    [Module] = [M || {attribute, _, module, M} <- Forms],
    Module.

declarations(Forms) ->
    [{module(Forms), [field_name(Field) || Field <- Fields]}
     || {attribute, _, record, {canonical_entry, Fields}} <- Forms].

field_name({typed_record_field, Field, _}) -> field_name(Field);
field_name({record_field, _, {atom, _, Name}}) -> Name;
field_name({record_field, _, {atom, _, Name}, _}) -> Name.

inventory(Forms) ->
    Module = module(Forms),
    Imports = maps:from_list([{FA, M} || {attribute, _, import, {M, FAs}} <- Forms,
                                       FA <- FAs]),
    lists:append([[{{Module, Name, Arity}, S} || S <- walk(Clauses, Module, Imports)]
                  || {function, _, Name, Arity, Clauses} <- Forms]).

walk({record, _, canonical_entry, Fields}, Module, Imports) ->
    [artifact_record | walk(Fields, Module, Imports)];
walk({record, _, Base, canonical_entry, Fields}, Module, Imports) ->
    [artifact_update | walk([Base, Fields], Module, Imports)];
walk({record_field, _, Base, canonical_entry, Field}, Module, Imports) ->
    [artifact_field | walk([Base, Field], Module, Imports)];
walk({record_index, _, canonical_entry, Field}, Module, Imports) ->
    [artifact_index | walk(Field, Module, Imports)];
walk({call, _, {remote, _, {atom, _, erlang}, {atom, _, apply}}, [Mod, Fun, Args]}, M, I) ->
    apply_sites(Mod, Fun, Args, M, I);
walk({call, _, {atom, _, apply}, [Mod, Fun, Args]}, M, I) ->
    apply_sites(Mod, Fun, Args, M, I);
walk({call, _, {remote, _, Mod, Fun}, Args}, M, I) ->
    remote_sites(Mod, Fun, length(Args), call, M, I) ++ walk(Args, M, I);
walk({call, _, {atom, _, Fun}, Args}, M, I) ->
    local_sites(Fun, length(Args), call, M, I) ++ walk(Args, M, I);
walk({'fun', _, {function, Mod, Fun, Arity}}, M, I) ->
    remote_sites(Mod, Fun, literal_arity(Arity), external_fun, M, I) ++ walk(Arity, M, I);
walk({'fun', _, {function, Fun, Arity}}, M, I) ->
    local_sites(Fun, Arity, local_fun, M, I);
walk({atom, _, canonical_entry}, _M, _I) -> [escaped_artifact_tag];
walk({atom, _, quod_ledger}, _M, _I) -> [escaped_codec_module];
walk({atom, _, quod_ledger_store}, _M, _I) -> [escaped_store_module];
walk(Term, M, I) when is_tuple(Term) -> walk(tuple_to_list(Term), M, I);
walk(Terms, M, I) when is_list(Terms) -> lists:append([walk(Term, M, I) || Term <- Terms]);
walk(_, _, _) -> [].

local_sites(Fun, Arity, Kind, Module, Imports) ->
    boundary(maps:get({Fun, Arity}, Imports, Module), Fun, Arity, Kind).

remote_sites({atom, _, Mod}, {atom, _, Fun}, Arity, Kind, _M, _I) ->
    boundary(Mod, Fun, Arity, Kind);
remote_sites({atom, _, Mod}, Fun, _Arity, _Kind, M, I)
  when Mod =:= quod_ledger; Mod =:= quod_ledger_store ->
    [{dynamic_owner_dispatch, Mod} | walk(Fun, M, I)];
remote_sites({atom, _, _Other}, Fun, _Arity, _Kind, M, I) -> walk(Fun, M, I);
remote_sites(Mod, {atom, _, Fun}, _Arity, _Kind, M, I)
  when Fun =:= entry; Fun =:= new_entry; Fun =:= noop_entry;
       Fun =:= decode_entry; Fun =:= from_entry_view; Fun =:= mint_artifact;
       Fun =:= encode_entry_view;
       Fun =:= append ->
    [{dynamic_boundary, Fun} | walk(Mod, M, I)];
remote_sites(Mod, {atom, _, _Other}, _Arity, _Kind, M, I) -> walk(Mod, M, I);
remote_sites(Mod, Fun, _Arity, _Kind, M, I) ->
    [dynamic_dispatch | walk([Mod, Fun], M, I)].

boundary(quod_ledger, Fun, Arity, Kind)
  when Fun =:= entry; Fun =:= new_entry; Fun =:= noop_entry;
       Fun =:= decode_entry; Fun =:= from_entry_view; Fun =:= mint_artifact;
       Fun =:= encode_entry_view ->
    [{Kind, quod_ledger, Fun, Arity}];
boundary(quod_ledger_store, append, Arity, Kind) ->
    [{Kind, quod_ledger_store, append, Arity}];
boundary(_, _, _, _) -> [].

apply_sites(Mod, Fun, Args, M, I) ->
    remote_sites(Mod, Fun, list_arity(Args), apply, M, I) ++ walk(Args, M, I).
literal_arity({integer, _, N}) -> N;
literal_arity(_) -> dynamic.
list_arity({nil, _}) -> 0;
list_arity({cons, _, _, Tail}) ->
    case list_arity(Tail) of dynamic -> dynamic; N -> N + 1 end;
list_arity(_) -> dynamic.

new_constructor_in_an_approved_module_is_not_authorized_test() ->
    Forms = [form("-module(quod_ledger)."),
             form("unchecked(B,V,K) -> {canonical_entry,B,V,K}.")],
    ?assertEqual([{{quod_ledger, unchecked, 3}, escaped_artifact_tag}],
                 inventory(Forms) -- reviewed_sites()).

duplicate_mint_in_approved_function_is_not_authorized_test() ->
    Forms = [form("-module(quod_ledger)."),
             form("mint_artifact(B,V,K) -> #canonical_entry{bytes=B,view=V,block=K}, "
                  "#canonical_entry{bytes=B,view=V,block=K}.")],
    ?assertEqual([{{quod_ledger, mint_artifact, 3}, artifact_record}],
                 inventory(Forms) -- reviewed_sites()).

new_ingress_in_an_approved_owner_is_not_authorized_test() ->
    Forms = [form("-module(quod_ledger_store)."),
             form("unchecked_cache(B) -> quod_ledger:decode_entry(B,wrapped).")],
    ?assertEqual([{{quod_ledger_store, unchecked_cache, 1},
                  {call, quod_ledger, decode_entry, 2}}],
                 inventory(Forms) -- reviewed_sites()).

duplicate_decode_at_an_approved_ingress_is_not_authorized_test() ->
    Forms = [form("-module(quod_ledger)."),
             form("decode_entry(B) -> quod_ledger:decode_entry(B,wrapped), "
                  "quod_ledger:decode_entry(B,wrapped).")],
    ?assertEqual([{{quod_ledger, decode_entry, 1}, {call, quod_ledger, decode_entry, 2}}],
                 inventory(Forms) -- reviewed_sites()).

checked_ingress_syntax_inventory_test() ->
    Forms = [form("-module(probe)."),
             form("-import(quod_ledger,[from_entry_view/1])."),
             form("direct(B) -> quod_ledger:decode_entry(B,wrapped)."),
             form("nested(B) -> fun() -> quod_ledger:decode_entry(B) end."),
             form("imported(V) -> from_entry_view(V)."),
             form("captured() -> fun quod_ledger:entry/2."),
             form("imported_fun() -> fun from_entry_view/1."),
             form("alias(B) -> M=quod_ledger, M:decode_entry(B)."),
             form("selected(F,A) -> quod_ledger:F(A)."),
             form("applied(V) -> apply(quod_ledger,from_entry_view,[V])."),
             form("remote_apply(S,A) -> erlang:apply(quod_ledger_store,append,[S,A])."),
             form("dynamic_apply(M,F,A) -> apply(M,F,A)."),
             form("mfa() -> {quod_ledger,decode_entry,2}."),
             form("forged(B,V,K) -> {canonical_entry,B,V,K}."),
             form("copied(A,V) -> A#canonical_entry{view=V}."),
             form("indexed() -> #canonical_entry.bytes."),
             form("field(A) -> A#canonical_entry.view.")],
    Expected = [
      {{probe,direct,1},{call,quod_ledger,decode_entry,2}},
      {{probe,nested,1},{call,quod_ledger,decode_entry,1}},
      {{probe,imported,1},{call,quod_ledger,from_entry_view,1}},
      {{probe,captured,0},{external_fun,quod_ledger,entry,2}},
      {{probe,imported_fun,0},{local_fun,quod_ledger,from_entry_view,1}},
      {{probe,alias,1},escaped_codec_module},
      {{probe,alias,1},{dynamic_boundary,decode_entry}},
      {{probe,selected,2},{dynamic_owner_dispatch,quod_ledger}},
      {{probe,applied,1},{apply,quod_ledger,from_entry_view,1}},
      {{probe,remote_apply,2},{apply,quod_ledger_store,append,2}},
      {{probe,dynamic_apply,3},dynamic_dispatch},
      {{probe,mfa,0},escaped_codec_module},
      {{probe,forged,3},escaped_artifact_tag},
      {{probe,copied,2},artifact_update},
      {{probe,indexed,0},artifact_index},
      {{probe,field,1},artifact_field}],
    ?assertEqual(lists:sort(Expected), lists:sort(inventory(Forms))).

form(Source) ->
    {ok, Tokens, _} = erl_scan:string(Source),
    {ok, Form} = erl_parse:parse_form(Tokens),
    Form.
