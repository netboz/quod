-module(quod_proof_context).
-moduledoc """
Private coordination state for one top-level ontology proof.

The context belongs to the origin proof worker and exists only for that
worker's lifetime.  It records one selected scope per pinned ontology identity
and the opaque invocation proxies used by nested `::` calls.  Nothing here is
an OTP service or transferable authority: callers must already execute in the
owning process, while nested requests are accepted only from a registered
scope worker.
""".

-include("quod_proof_limits.hrl").

-export([start/2, stop/2, proof_id/0,
         read_only/0, get_or_open_scope/2, registered_scope/1,
         new_proxy/2, proxy/2, update_proxy/3, drop_proxy/2,
         mark_dirty/2, foreign_dirty/0]).
-ifdef(TEST).
-export([scopes/0]).
-endif.

-record(ctx, {proof_id  :: <<_:256>>,
              read_only = false :: boolean(),
              scopes = #{} :: map(),
              namespaces = #{} :: map(),
              scope_pids = #{} :: map(),
              proxies = #{} :: map(),
              dirty = #{} :: map()}).

-define(KEY, '$quod_proof_context').

-type identity() :: {binary(), <<_:256>>}.
-type handle() :: {quod_proof_context, <<_:256>>, pid()}.
-export_type([identity/0, handle/0]).

-doc "Start the one proof context owned by the calling worker.".
-spec start(<<_:256>>, boolean()) -> handle().
start(<<_:256>> = ProofId, ReadOnly) when is_boolean(ReadOnly) ->
    undefined = get(?KEY),
    put(?KEY, #ctx{proof_id = ProofId, read_only = ReadOnly}),
    {quod_proof_context, ProofId, self()}.

-doc "Close every selected scope and retained invocation proxy, then erase the context.".
-spec stop(fun((term()) -> term()), fun(({pid(), term()}) -> term())) -> ok.
stop(CloseScopeFun, CloseProxyFun)
  when is_function(CloseScopeFun, 1), is_function(CloseProxyFun, 1) ->
    case erase(?KEY) of
        #ctx{scopes = Scopes, proxies = Proxies} ->
            maps:foreach(
              fun(_Ref, Proxy) ->
                  try CloseProxyFun(Proxy) catch _:_ -> ok end
              end, Proxies),
            maps:foreach(
              fun(_Identity, Scope) ->
                  try CloseScopeFun(Scope) catch _:_ -> ok end
              end, Scopes),
            ok;
        undefined ->
            ok
    end.

-spec proof_id() -> <<_:256>>.
proof_id() -> (context())#ctx.proof_id.

-spec read_only() -> boolean().
read_only() -> (context())#ctx.read_only.

-doc "Return the existing pinned scope or open and register it exactly once.".
-spec get_or_open_scope(identity(), fun(() -> {ok, pid(), term()} | {error, term()})) ->
          {ok, term()} | {error, term()}.
get_or_open_scope({Ns, <<_:256>> = Anchor} = Identity, OpenFun)
  when is_binary(Ns), is_function(OpenFun, 0) ->
    Ctx0 = context(),
    case maps:find(Identity, Ctx0#ctx.scopes) of
        {ok, Scope} ->
            {ok, Scope};
        error ->
            case maps:find(Ns, Ctx0#ctx.namespaces) of
                {ok, OtherAnchor} when OtherAnchor =/= Anchor ->
                    {error, {anchor_conflict, Ns}};
                _ when map_size(Ctx0#ctx.scopes) >= ?QUOD_MAX_SCOPES_PER_PROOF ->
                    {error, too_many_scopes};
                _ ->
                    open_scope(Identity, Ns, Anchor, OpenFun, Ctx0)
            end
    end.

open_scope(Identity, Ns, Anchor, OpenFun, Ctx0) ->
    case OpenFun() of
        {ok, Pid, Scope} when is_pid(Pid) ->
            Scopes1 = (Ctx0#ctx.scopes)#{Identity => Scope},
            Namespaces1 = (Ctx0#ctx.namespaces)#{Ns => Anchor},
            Pids1 = (Ctx0#ctx.scope_pids)#{Pid => Identity},
            put_context(Ctx0#ctx{scopes = Scopes1,
                                 namespaces = Namespaces1,
                                 scope_pids = Pids1}),
            {ok, Scope};
        {error, _} = Error ->
            Error;
        _ ->
            {error, broken_scope}
    end.

-spec registered_scope(pid()) -> boolean().
registered_scope(Pid) when Pid =:= self() -> true;
registered_scope(Pid) when is_pid(Pid) ->
    maps:is_key(Pid, (context())#ctx.scope_pids);
registered_scope(_) -> false.

-ifdef(TEST).
-spec scopes() -> [term()].
scopes() -> maps:values((context())#ctx.scopes).
-endif.

-doc "Create an origin-owned opaque proxy for one logical invocation.".
-spec new_proxy(pid(), term()) ->
          {ok, reference()} | {error, not_allowed | too_many_proxies}.
new_proxy(Owner, Stream) when is_pid(Owner) ->
    case registered_scope(Owner) of
        false -> {error, not_allowed};
        true ->
            Ctx0 = context(),
            case map_size(Ctx0#ctx.proxies) >= ?QUOD_MAX_PROXIES_PER_PROOF of
                true -> {error, too_many_proxies};
                false ->
                    Ref = make_ref(),
                    put_context(Ctx0#ctx{proxies =
                                           (Ctx0#ctx.proxies)#{
                                             Ref => {Owner, Stream}}}),
                    {ok, Ref}
            end
    end.

-spec proxy(reference(), pid()) -> {ok, term()} | {error, not_allowed | unknown_proxy}.
proxy(Ref, Owner) when is_reference(Ref), is_pid(Owner) ->
    case maps:find(Ref, (context())#ctx.proxies) of
        {ok, {Owner, Stream}} -> {ok, Stream};
        {ok, _} -> {error, not_allowed};
        error -> {error, unknown_proxy}
    end.

-spec update_proxy(reference(), pid(), term()) -> ok | {error, not_allowed | unknown_proxy}.
update_proxy(Ref, Owner, Stream) ->
    case proxy(Ref, Owner) of
        {ok, _Old} ->
            Ctx0 = context(),
            put_context(Ctx0#ctx{proxies =
                                   (Ctx0#ctx.proxies)#{Ref => {Owner, Stream}}}),
            ok;
        {error, _} = Error -> Error
    end.

-spec drop_proxy(reference(), pid()) -> ok | {error, not_allowed | unknown_proxy}.
drop_proxy(Ref, Owner) ->
    case proxy(Ref, Owner) of
        {ok, _Stream} ->
            Ctx0 = context(),
            put_context(Ctx0#ctx{proxies = maps:remove(Ref, Ctx0#ctx.proxies)}),
            ok;
        {error, _} = Error -> Error
    end.

-spec mark_dirty(pid(), boolean()) -> ok | {error, not_allowed}.
mark_dirty(Pid, Dirty) when is_pid(Pid), is_boolean(Dirty) ->
    case maps:is_key(Pid, (context())#ctx.scope_pids) of
        false -> {error, not_allowed};
        true ->
            Ctx0 = context(),
            put_context(Ctx0#ctx{dirty = (Ctx0#ctx.dirty)#{Pid => Dirty}}),
            ok
    end.

-spec foreign_dirty() -> boolean().
foreign_dirty() ->
    lists:any(fun(Value) -> Value =:= true end,
              maps:values((context())#ctx.dirty)).

context() ->
    case get(?KEY) of
        #ctx{} = Ctx -> Ctx;
        undefined -> erlang:error(no_proof_context)
    end.

put_context(#ctx{} = Ctx) -> put(?KEY, Ctx), ok.
