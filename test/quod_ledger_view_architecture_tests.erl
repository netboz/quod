-module(quod_ledger_view_architecture_tests).

-include_lib("eunit/include/eunit.hrl").

%% Inspect production forms, not the TEST-enabled BEAM: test-only store setup
%% must neither authorize a live scan nor make the production inventory noisy.
%% Owning MFAs and occurrence counts are deliberate; approving a module would
%% let a new live reader in that same module silently acquire a path capability.
production_full_open_inventory_test() ->
    Root = source_root(),
    Files = lists:sort(filelib:fold_files(filename:join(Root, "src"),
                                        "\\.erl$", true,
                                        fun(File, Acc) -> [File | Acc] end, [])),
    ?assert(Files =/= []),
    Inventory = lists:append([inventory(production_forms(File, Root)) || File <- Files]),
    ?assertEqual(lists:sort(reviewed_sites()), lists:sort(Inventory)).

reviewed_sites() ->
    [%% Hosted owner startup/restore: subsequent replay reuses this handle.
     {{quod_simplex, init_store, 3}, {call, open, 2}},
     %% Pre-owner create/join/resume inspects the durable founding identity.
     {{quod_ontology, existing_ledger, 2}, {call, open_ro, 2}},
     %% The existing foreign cache owner reconstructs its first/recovery index.
     {{quod_foreign_log, open_cache_raw, 6}, {call, open, 3}},
     %% Explicit stopped-ledger inspection, never a live-view failure fallback.
     {{quod_explorer_http, with_offline_store, 3}, {call, open_ro, 2}},
     %% Public default-mode API delegation, not additional recovery owners.
     {{quod_ledger_store, open, 2}, {call, open, 3}},
     {{quod_ledger_store, open_ro, 2}, {call, open_ro, 3}},
     %% The sole opaque remote dispatch is the governed predicate registry,
     %% not a ledger-open permission. Pin it too so new dynamic wrappers require
     %% review instead of bypassing the statically named full-open inventory.
     {{quod_predicates, dispatch, 3}, dynamic_dispatch}].

source_root() ->
    Source = proplists:get_value(source, ?MODULE:module_info(compile)),
    filename:dirname(filename:dirname(filename:absname(Source))).

production_forms(File, Root) ->
    {ok, Forms} = epp:parse_file(File, [filename:join(Root, "include")], []),
    %% Includes/macros are expanded without defining TEST. Never silently skip
    %% a source file whose preprocessor could not expose all its call sites.
    ?assertEqual({File, []}, {File, [E || {error, E} <- Forms]}),
    Forms.

inventory(Forms) ->
    [Module] = [M || {attribute, _, module, M} <- Forms],
    Imports = maps:from_list([{FA, M} || {attribute, _, import, {M, FAs}} <- Forms,
                                       FA <- FAs]),
    lists:append(
      [[{{Module, Name, Arity}, Site} || Site <- walk(Clauses, Module, Imports)]
       || {function, _, Name, Arity, Clauses} <- Forms]).

walk({call, _, {remote, _, {atom, _, erlang}, {atom, _, apply}},
      [Mod, Fun, Args]}, Module, Imports) ->
    apply_sites(Mod, Fun, Args, Module, Imports);
walk({call, _, {atom, _, apply}, [Mod, Fun, Args]}, Module, Imports) ->
    apply_sites(Mod, Fun, Args, Module, Imports);
walk({call, _, {remote, _, Mod, Fun}, Args}, Module, Imports) ->
    remote_sites(Mod, Fun, length(Args), call, Module, Imports) ++
        walk(Args, Module, Imports);
walk({call, _, {atom, _, Fun}, Args}, Module, Imports) ->
    local_sites(Fun, length(Args), call, Module, Imports) ++ walk(Args, Module, Imports);
walk({'fun', _, {function, Mod, Fun, Arity}}, Module, Imports) ->
    remote_sites(Mod, Fun, literal_arity(Arity), external_fun, Module, Imports) ++
        walk(Arity, Module, Imports);
walk({'fun', _, {function, Fun, Arity}}, Module, Imports) ->
    local_sites(Fun, Arity, local_fun, Module, Imports);
walk({atom, _, quod_ledger_store}, _Module, _Imports) ->
    %% M = quod_ledger_store; M:open_ro(...), an MFA tuple, or a module-returning
    %% helper must not hide a path open behind an unreviewed alias/wrapper.
    [escaped_ledger_module];
walk(Term, Module, Imports) when is_tuple(Term) ->
    walk(tuple_to_list(Term), Module, Imports);
walk(Terms, Module, Imports) when is_list(Terms) ->
    lists:append([walk(Term, Module, Imports) || Term <- Terms]);
walk(_Term, _Module, _Imports) ->
    [].

local_sites(Fun, Arity, Kind, Module, Imports) ->
    case maps:get({Fun, Arity}, Imports, Module) of
        quod_ledger_store -> full_open(Fun, Arity, Kind);
        _ -> []
    end.

remote_sites({atom, _, quod_ledger_store}, {atom, _, Fun}, Arity, Kind, _, _) ->
    full_open(Fun, Arity, Kind);
remote_sites({atom, _, quod_ledger_store}, Fun, _Arity, _Kind, Module, Imports) ->
    [dynamic_ledger_dispatch | walk(Fun, Module, Imports)];
remote_sites({atom, _, _Other}, Fun, _Arity, _Kind, Module, Imports) ->
    walk(Fun, Module, Imports);
remote_sites(Mod, {atom, _, Fun}, _Arity, _Kind, Module, Imports)
  when Fun =:= open; Fun =:= open_ro ->
    [dynamic_full_open | walk(Mod, Module, Imports)];
remote_sites(Mod, {atom, _, _Other}, _Arity, _Kind, Module, Imports) ->
    walk(Mod, Module, Imports);
remote_sites(Mod, Fun, _Arity, _Kind, Module, Imports) ->
    [dynamic_dispatch | walk([Mod, Fun], Module, Imports)].

full_open(Fun, Arity, Kind) when Fun =:= open; Fun =:= open_ro ->
    [{Kind, Fun, Arity}];
full_open(_Fun, _Arity, _Kind) ->
    [].

literal_arity({integer, _, Arity}) -> Arity;
literal_arity(_) -> dynamic.

apply_sites({atom, _, Mod}, {atom, _, Fun}, Args, Module, Imports) ->
    %% A literal apply/3 is still a full-open call site. Unknown argument-list
    %% length remains visible, rather than accidentally approving an arity.
    remote_sites({atom, 0, Mod}, {atom, 0, Fun}, list_arity(Args),
                 apply, Module, Imports) ++ walk(Args, Module, Imports);
apply_sites(Mod, Fun, Args, Module, Imports) ->
    remote_sites(Mod, Fun, list_arity(Args), apply, Module, Imports) ++
        walk(Args, Module, Imports).

list_arity({nil, _}) -> 0;
list_arity({cons, _, _, Tail}) ->
    case list_arity(Tail) of dynamic -> dynamic; N -> N + 1 end;
list_arity(_) -> dynamic.

%% Positive controls pin the detector, including calls hidden by syntax that a
%% grep would miss. No source line or whole-module permission is involved.
same_module_new_live_open_is_not_authorized_test() ->
    Forms = [form("-module(quod_simplex)."),
             form("init_store(N,C,I) -> quod_ledger_store:open(N,C), I."),
             form("live_page(N,P) -> quod_ledger_store:open_ro(N,P).")],
    ?assertEqual([{{quod_simplex, live_page, 2}, {call, open_ro, 2}}],
                 inventory(Forms) -- reviewed_sites()).

duplicate_open_in_approved_owner_is_not_authorized_test() ->
    Forms = [form("-module(quod_simplex)."),
             form("init_store(N,C,I) -> quod_ledger_store:open(N,C), "
                  "quod_ledger_store:open(N,C), I.")],
    ?assertEqual([{{quod_simplex, init_store, 3}, {call, open, 2}}],
                 inventory(Forms) -- reviewed_sites()).

full_open_syntax_inventory_test() ->
    Forms = [form("-module(probe)."),
             form("-import(quod_ledger_store,[open_ro/2])."),
             form("direct(N,P) -> quod_ledger_store:open(N,P,wrapped)."),
             form("nested(N,P) -> fun() -> quod_ledger_store:open_ro(N,P) end."),
             form("imported(N,P) -> open_ro(N,P)."),
             form("captured() -> fun quod_ledger_store:open/2."),
             form("imported_fun() -> fun open_ro/2."),
             form("alias(N,P) -> M = quod_ledger_store, M:open_ro(N,P)."),
             form("selected(F,N,P) -> quod_ledger_store:F(N,P)."),
             form("applied(N,P) -> apply(quod_ledger_store,open_ro,[N,P])."),
             form("remote_apply(N,P) -> erlang:apply(quod_ledger_store,open,[N,P,wrapped])."),
             form("dynamic_apply(M,F,A) -> apply(M,F,A)."),
             form("mfa() -> {quod_ledger_store,open_ro,2}.")],
    ?assertEqual(lists:sort(
       [{{probe, direct, 2}, {call, open, 3}},
        {{probe, nested, 2}, {call, open_ro, 2}},
        {{probe, imported, 2}, {call, open_ro, 2}},
        {{probe, captured, 0}, {external_fun, open, 2}},
        {{probe, imported_fun, 0}, {local_fun, open_ro, 2}},
        {{probe, alias, 2}, escaped_ledger_module},
        {{probe, alias, 2}, dynamic_full_open},
        {{probe, selected, 3}, dynamic_ledger_dispatch},
        {{probe, applied, 2}, {apply, open_ro, 2}},
        {{probe, remote_apply, 2}, {apply, open, 3}},
        {{probe, dynamic_apply, 3}, dynamic_dispatch},
        {{probe, mfa, 0}, escaped_ledger_module}]), lists:sort(inventory(Forms))).

form(Source) ->
    {ok, Tokens, _} = erl_scan:string(Source),
    {ok, Form} = erl_parse:parse_form(Tokens),
    Form.
