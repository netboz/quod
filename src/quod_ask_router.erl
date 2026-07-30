-module(quod_ask_router).
-moduledoc """
The node-local return router for remote `::` asks.

Remote asks share one authenticated return channel per asking node.  The target
multiplexes `{AskId, Reply}` frames over that channel; this process owns its
single subscription and delivers each reply only to the proof worker that
registered the matching id.  It avoids consuming one QUIC stream per proof,
while retaining the per-ask ownership and peer-identity checks at the boundary.
""".

-behaviour(gen_server).

-include("quod_transport_limits.hrl").

-export([start_link/0, register/2, unregister/1, answer_channel/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(entry, {owner :: pid(),
                owner_mref :: reference(),
                expected_key :: binary(),
                link = undefined :: undefined | pid()}).

-record(s, {channel :: binary(),
            entries = #{} :: #{binary() => #entry{}},
            owners = #{} :: #{reference() => binary()},
            links = #{} :: #{pid() => reference()}}).

-define(KEY, {ask_router, node}).
-define(TAG, quod_ask_answer).

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link(quod_reg:via(?KEY), ?MODULE, [], []).

%% Register the calling proof worker before its open frame can be sent.  The
%% router monitors it, so a killed HTTP/proof worker cannot retain an entry.
-spec register(binary(), binary()) -> {ok, binary()} | {error, unavailable}.
register(AskId, ExpectedKey)
  when is_binary(AskId), byte_size(AskId) =:= 16,
       is_binary(ExpectedKey), byte_size(ExpectedKey) =:= 32 ->
    try gen_server:call(quod_reg:via(?KEY), {register, AskId, self(), ExpectedKey})
    catch exit:_ -> {error, unavailable}
    end.

-spec unregister(binary()) -> ok.
unregister(AskId) when is_binary(AskId) ->
    try gen_server:cast(quod_reg:via(?KEY), {unregister, AskId})
    catch exit:_ -> ok
    end,
    ok.

-spec answer_channel() -> binary().
answer_channel() ->
    case application:get_env(quod, node_pubkey) of
        {ok, NodeKey} when is_binary(NodeKey), byte_size(NodeKey) =:= 32 ->
            channel(NodeKey);
        _ ->
            error(node_pubkey_required)
    end.

init([]) ->
    Channel = answer_channel(),
    _ = quod_reg:subscribe({channel, Channel}),
    {ok, #s{channel = Channel}}.

handle_call({register, AskId, Owner, ExpectedKey}, _From,
            S = #s{channel = Channel, entries = Entries}) ->
    case maps:is_key(AskId, Entries) of
        true ->
            {reply, {error, unavailable}, S};
        false ->
            OwnerMRef = monitor(process, Owner),
            Entry = #entry{owner = Owner, owner_mref = OwnerMRef,
                           expected_key = ExpectedKey},
            {reply, {ok, Channel},
             S#s{entries = Entries#{AskId => Entry},
                 owners = (S#s.owners)#{OwnerMRef => AskId}}}
    end;
handle_call(_Request, _From, S) ->
    {reply, {error, unknown_request}, S}.

handle_cast({unregister, AskId}, S) ->
    {noreply, drop_entry(AskId, S)};
handle_cast(_Message, S) ->
    {noreply, S}.

%% A reply is accepted only from the exact key selected by the directory route.
%% The channel is shared, but the random ask id remains the delivery capability.
handle_info({quod_message, {PeerIdentity, LinkPid}, Channel, Payload},
            S = #s{channel = Channel, entries = Entries}) when is_pid(LinkPid) ->
    case decode_reply(Payload) of
        {ok, AskId, Reply} -> route_reply(AskId, Reply, PeerIdentity, LinkPid, Entries, S);
        error ->
            {noreply, S}
    end;
handle_info({'DOWN', MRef, process, _Pid, _Reason},
            S = #s{owners = Owners, links = Links}) ->
    case maps:get(MRef, Owners, undefined) of
        AskId when is_binary(AskId) ->
            {noreply, drop_entry(AskId, S)};
        undefined ->
            case link_for_monitor(MRef, Links) of
                undefined -> {noreply, S};
                LinkPid -> {noreply, drop_link(LinkPid, S)}
            end
    end;
handle_info(_Info, S) ->
    {noreply, S}.

terminate(_Reason, #s{channel = Channel}) ->
    _ = try quod_reg:unsubscribe({channel, Channel}) catch _:_ -> ok end,
    ok.

channel(NodeKey) ->
    term_to_binary({?TAG, NodeKey}, [deterministic]).

%% Decode the frame once at the shared protocol boundary. The worker receives
%% this already-bounded term and still validates its ask id, sequence, and body.
decode_reply(Payload) when is_binary(Payload) ->
    case quod_safe_term:decode(Payload, ?QUOD_TRANSPORT_MAX_FRAME_BYTES) of
        {ok, Reply = {quod_ask_answer, AskId, _Seq, _Body}}
          when is_binary(AskId), byte_size(AskId) =:= 16 -> {ok, AskId, Reply};
        _ -> error
    end;
decode_reply(_) -> error.

route_reply(AskId, Reply, PeerIdentity, LinkPid, Entries, S) ->
    case maps:get(AskId, Entries, undefined) of
        #entry{owner = Owner, expected_key = ExpectedKey} = Entry ->
            case peer_key(PeerIdentity) =:= ExpectedKey of
                true ->
                    case remember_link(LinkPid, AskId, Entry, S) of
                        {ok, S1} ->
                            Owner ! {quod_ask_answer, AskId, Reply},
                            {noreply, S1};
                        error ->
                            {noreply, S}
                    end;
                false ->
                    {noreply, S}
            end;
        _ ->
            {noreply, S}
    end.

peer_key({NodeKey, _Endpoint}) when is_binary(NodeKey) -> NodeKey;
peer_key(NodeKey) when is_binary(NodeKey) -> NodeKey;
peer_key(_) -> undefined.

remember_link(LinkPid, AskId, Entry, S = #s{entries = Entries, links = Links}) ->
    case Entry#entry.link of
        undefined ->
            MRef = case maps:get(LinkPid, Links, undefined) of
                       undefined -> monitor(process, LinkPid);
                       Existing -> Existing
                   end,
            {ok, S#s{entries = Entries#{AskId => Entry#entry{link = LinkPid}},
                      links = Links#{LinkPid => MRef}}};
        LinkPid ->
            {ok, S};
        _Other ->
            %% One ask must not silently switch to another return stream.
            error
    end.

drop_entry(AskId, S = #s{entries = Entries, owners = Owners}) ->
    case maps:take(AskId, Entries) of
        {#entry{owner_mref = OwnerMRef, link = LinkPid}, Entries1} ->
            demonitor(OwnerMRef, [flush]),
            S1 = S#s{entries = Entries1, owners = maps:remove(OwnerMRef, Owners)},
            maybe_drop_link_monitor(LinkPid, S1);
        error -> S
    end.

maybe_drop_link_monitor(undefined, S) -> S;
maybe_drop_link_monitor(LinkPid, S = #s{entries = Entries, links = Links}) ->
    case lists:any(fun(#entry{link = Link}) -> Link =:= LinkPid end,
                   maps:values(Entries)) of
        true -> S;
        false ->
            case maps:take(LinkPid, Links) of
                {MRef, Links1} -> demonitor(MRef, [flush]), S#s{links = Links1};
                error -> S
            end
    end.

link_for_monitor(MRef, Links) ->
    maps:fold(fun(LinkPid, Ref, Acc) ->
                      case Acc of undefined when Ref =:= MRef -> LinkPid; _ -> Acc end
              end, undefined, Links).

drop_link(LinkPid, S = #s{entries = Entries, links = Links}) ->
    case maps:take(LinkPid, Links) of
        {_MRef, Links1} ->
            %% This is the monitor's own DOWN; no demonitor call is needed.
            {Gone, Kept} = maps:fold(
                             fun(AskId, Entry = #entry{link = Link}, {Drop, Keep}) ->
                                 case Link =:= LinkPid of
                                     true -> {[{AskId, Entry} | Drop], Keep};
                                     false -> {Drop, Keep#{AskId => Entry}}
                                 end
                             end, {[], #{}}, Entries),
            lists:foreach(
              fun({AskId, #entry{owner = Owner, owner_mref = OwnerMRef}}) ->
                  Owner ! {quod_ask_stream_down, AskId},
                  demonitor(OwnerMRef, [flush])
              end, Gone),
            S#s{entries = Kept,
                owners = maps:without([(Entry#entry.owner_mref) || {_Id, Entry} <- Gone],
                                      S#s.owners),
                links = Links1};
        error -> S
    end.
