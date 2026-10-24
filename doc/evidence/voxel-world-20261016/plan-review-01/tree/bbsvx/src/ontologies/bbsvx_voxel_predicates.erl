%%%-----------------------------------------------------------------------------
%%% BBSvx Voxel World Predicates
%%%-----------------------------------------------------------------------------
%%% External predicates for procedural terrain generation.
%%%
%%% generate_chunk(OffsetX, OffsetZ, Size, Seed, SeaLevel)
%%%   Generates a Size x Size terrain chunk at world coordinates (OffsetX, OffsetZ).
%%%   Uses a single scope_prove call to bbsvx:voxel for terrain computation
%%%   (via generate_terrain_data/6 findall), then asserts block/4 facts locally.
%%%
%%% Architecture C: terrain rules (noise, biomes, block selection) live in
%%% bbsvx:voxel and are called via :: scoped proving. Block data is asserted
%%% locally in the caller's ontology.
%%%-----------------------------------------------------------------------------

-module(bbsvx_voxel_predicates).

-include("bbsvx.hrl").

-export([external_predicates/0, runtime_predicates/0]).
-export([pred_generate_chunk/3, pred_generate_collider/3]).

-define(VOXEL_PREDS, [
    {{generate_chunk, 5}, ?MODULE, pred_generate_chunk},
    {{generate_collider, 5}, ?MODULE, pred_generate_collider}
]).

-spec external_predicates() -> list().
external_predicates() ->
    ?VOXEL_PREDS.

-spec runtime_predicates() -> list().
runtime_predicates() ->
    ?VOXEL_PREDS.

%%------------------------------------------------------------------------------
%% DEPRECATED: generate_chunk/5
%%
%% Use generate_collider/5 for client-side terrain architecture (issue #218).
%% With client-side generation, the Ontiris client generates terrain locally
%% via SWI-Prolog WASM and only requests colliders from the server.
%%
%% This predicate is kept for backward compatibility with demo scripts and
%% older clients that still use server-side terrain generation.
%%
%% Generates a Size x Size chunk starting at (OffsetX, OffsetZ).
%% Asserts block/4 facts locally AND creates a physics collider.
%%------------------------------------------------------------------------------
pred_generate_chunk({generate_chunk, OxArg, OzArg, SizeArg, SeedArg, SeaArg},
                    Next, #est{bs = Bs} = St) ->
    Ox = resolve_int(erlog_int:dderef(OxArg, Bs)),
    Oz = resolve_int(erlog_int:dderef(OzArg, Bs)),
    Size = resolve_int(erlog_int:dderef(SizeArg, Bs)),
    Seed = resolve_int(erlog_int:dderef(SeedArg, Bs)),
    _SeaLevel = resolve_int(erlog_int:dderef(SeaArg, Bs)),
    case {is_integer(Ox), is_integer(Oz), is_integer(Size), is_integer(Seed)} of
        {true, true, true, true} ->
            CallerNs = proplists:get_value(ontology_namespace, St#est.fs),
            ScopeId = ulid:generate(),
            InvocationId = ulid:generate(),
            Goal = {generate_terrain_data, Ox, Oz, Size, Seed, {1}, {2}},
            case bbsvx_actor_ontology:scope_prove(
                    <<"bbsvx:voxel">>, ScopeId, InvocationId,
                    Goal, CallerNs, []) of
                {ok, {generate_terrain_data, _, _, _, _,
                      BlocksList, SurfacesList}} ->

                    %% Assert each block into caller's state
                    St1 = assert_block_list(BlocksList, St),
                    Count = count_erlog_list(BlocksList),
                    logger:info("generate_chunk: created ~p blocks", [Count]),

                    %% Build flat position list for voxel collider
                    Positions = surfaces_to_positions(SurfacesList),

                    %% Record effect for collision
                    ChunkId = iolist_to_binary(
                        io_lib:format("chunk_~p_~p", [Ox, Oz])),
                    Ns = proplists:get_value(ontology_namespace, St1#est.fs),
                    SourceId = case proplists:get_value(
                        goal_source_id, St1#est.fs) of
                        undefined -> bbsvx_crypto_service:my_id();
                        Sid -> Sid
                    end,
                    EffectDesc = {exec_add_voxel_collider, ChunkId, Positions},
                    Effect = #effect{
                        type = construct_effect,
                        execute_on = all,
                        source_id = SourceId,
                        params = #{
                            effect_descriptor => EffectDesc,
                            source_namespace => Ns
                        }
                    },
                    St2 = bbsvx_common_predicates:add_effect(St1, Effect),
                    erlog_int:prove_body(Next, St2);
                {error, Reason} ->
                    logger:warning("generate_chunk: scope_prove failed: ~p",
                                   [Reason]),
                    erlog_int:fail(St)
            end;
        _ ->
            erlog_int:fail(St)
    end.

%%------------------------------------------------------------------------------
%% Assert a list of b(X, Y, Z, Type) terms from an Erlog list into caller's state.
%%------------------------------------------------------------------------------
assert_block_list([], St) ->
    St;
assert_block_list([{b, X, Y, Z, Type} | Rest], St) ->
    St1 = assert_block(X, Y, Z, Type, St),
    assert_block_list(Rest, St1);
assert_block_list([_ | Rest], St) ->
    assert_block_list(Rest, St).

%%------------------------------------------------------------------------------
%% Assert a single block(X, Y, Z, Type) fact into the ontology.
%%------------------------------------------------------------------------------
assert_block(X, Y, Z, BlockType, St) ->
    {succeed, St1} = erlog_int:prove_goal(
        {assertz, {block, X, Y, Z, BlockType}}, St),
    St1.

%%------------------------------------------------------------------------------
%% Convert Erlog list of s(X, H, Z) to flat position list [X1,Y1,Z1, ...].
%%------------------------------------------------------------------------------
surfaces_to_positions(ErlogList) ->
    surfaces_to_positions(ErlogList, []).

surfaces_to_positions([], Acc) ->
    lists:reverse(Acc);
surfaces_to_positions([{s, X, H, Z} | Rest], Acc) ->
    surfaces_to_positions(Rest, [Z, H, X | Acc]);
surfaces_to_positions([_ | Rest], Acc) ->
    surfaces_to_positions(Rest, Acc).

%%------------------------------------------------------------------------------
%% Count elements in an Erlog list.
%%------------------------------------------------------------------------------
count_erlog_list(List) when is_list(List) ->
    length(List);
count_erlog_list(_) ->
    0.

%%------------------------------------------------------------------------------
%% Resolve Erlog negative numbers: {'-', N} → -N, integers pass through.
%%------------------------------------------------------------------------------
resolve_int({'-', N}) when is_integer(N) -> -N;
resolve_int(N) when is_integer(N) -> N;
resolve_int(Other) -> Other.

%%------------------------------------------------------------------------------
%% generate_collider(OffsetX, OffsetZ, Size, Seed, SeaLevel)
%%
%% Collider-only terrain path for client-side generation architecture (#218).
%% Computes the heightmap from seed (pure function) and creates a Rapier
%% voxel collider via exec_add_voxel_collider effect. Does NOT assert block/4
%% facts — the client generates blocks locally via SWI-Prolog WASM.
%%
%% The collider entity_id is "chunk_<Ox>_<Oz>", which is stable across
%% recreations to support future remove+recreate on block modifications.
%%
%% NOTE: This still calls scope_prove into bbsvx:voxel to run
%% generate_terrain_data/6 — the voxel ontology actor is blocked during
%% heightmap computation (~180ms per chunk). This is acceptable because:
%%   1. No assertz operations (was ~1024 per chunk, now zero)
%%   2. No EPTO broadcast of block diffs (was the main bottleneck)
%%   3. Heightmap-only computation is much lighter than full block gen
%% Future optimization: pure Erlang heightmap (no Prolog scope_prove).
%%------------------------------------------------------------------------------
pred_generate_collider({generate_collider, OxArg, OzArg, SizeArg, SeedArg, SeaArg},
                       Next, #est{bs = Bs} = St) ->
    Ox = resolve_int(erlog_int:dderef(OxArg, Bs)),
    Oz = resolve_int(erlog_int:dderef(OzArg, Bs)),
    Size = resolve_int(erlog_int:dderef(SizeArg, Bs)),
    Seed = resolve_int(erlog_int:dderef(SeedArg, Bs)),
    _SeaLevel = resolve_int(erlog_int:dderef(SeaArg, Bs)),
    case {is_integer(Ox), is_integer(Oz), is_integer(Size), is_integer(Seed)} of
        {true, true, true, true} ->
            CallerNs = proplists:get_value(ontology_namespace, St#est.fs),
            ScopeId = ulid:generate(),
            InvocationId = ulid:generate(),
            Goal = {generate_terrain_data, Ox, Oz, Size, Seed, {1}, {2}},
            case bbsvx_actor_ontology:scope_prove(
                    <<"bbsvx:voxel">>, ScopeId, InvocationId,
                    Goal, CallerNs, []) of
                {ok, {generate_terrain_data, _, _, _, _,
                      _BlocksList, SurfacesList}} ->

                    %% No block assertions — client generates blocks locally

                    %% Build flat position list for voxel collider
                    Positions = surfaces_to_positions(SurfacesList),

                    %% Record effect for collision
                    ChunkId = iolist_to_binary(
                        io_lib:format("chunk_~p_~p", [Ox, Oz])),
                    Ns = proplists:get_value(ontology_namespace, St#est.fs),
                    SourceId = case proplists:get_value(
                        goal_source_id, St#est.fs) of
                        undefined -> bbsvx_crypto_service:my_id();
                        Sid -> Sid
                    end,
                    EffectDesc = {exec_add_voxel_collider, ChunkId, Positions},
                    Effect = #effect{
                        type = construct_effect,
                        execute_on = all,
                        source_id = SourceId,
                        params = #{
                            effect_descriptor => EffectDesc,
                            source_namespace => Ns
                        }
                    },
                    St1 = bbsvx_common_predicates:add_effect(St, Effect),
                    erlog_int:prove_body(Next, St1);
                {error, Reason} ->
                    logger:warning("generate_collider: scope_prove failed: ~p",
                                   [Reason]),
                    erlog_int:fail(St)
            end;
        _ ->
            erlog_int:fail(St)
    end.
