-module(quod_agent_vault).
-moduledoc """
Node-local encrypted custody for ontology-backed agent keys.

The containing ontology owns assignments and active/revoked key state. This
service owns only secret files, bound to the network, exact agent reference and
public key. It also retains a pending custody-establishing signed request
until the governing caller certifies its handoff or retirement. It never
submits requests or decides outcomes. Its in-VM API backs governed key preparation and signing;
it is not a public permission boundary. Requests use the existing signed-goal
schema and encoder. No arbitrary-byte signing operation exists.

The operator supplies a separate 32-byte unlock file outside the vault directory.
Only an opaque closure retains that material, as with `m:quod_identity`; this
prevents accidental diagnostic disclosure, not inspection by code inside the VM.
""".
-behaviour(gen_server).

-include_lib("kernel/include/file.hrl").
-include("quod_client_goal_limits.hrl").

-export([start_link/0, start_link/1, prepare/2, prepare/3, sign/2, delete/2,
         retained/1, retain/3, retire/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, format_status/1]).

-record(s, {directory :: file:filename(), unlock :: fun(() -> binary()),
            sync_pending = false :: boolean(), receipts = #{} :: map()}).
-define(LISTENER, quod_agent_vault_listener).
-define(DOMAIN, <<"quod.agent.key.v2", 0>>).

start_link() ->
    case application:get_env(quod, agent_vault) of
        {ok, Config} -> start_link(Config);
        undefined -> ignore
    end.

-spec start_link(map()) -> gen_server:start_ret().
start_link(Config) -> gen_server:start_link(quod_reg:via({agent_vault, node}), ?MODULE, Config, []).

-doc """
Prepare stable custody for the next assignment after `ExpectedEpoch` (zero for
the first assignment).
One atomic slot per agent retains the same random key across a lost reply or
vault restart. Advancing the slot preserves previously published custody;
requests for an older epoch fail. The governing caller must verify the exact
committed assignment and candidate promise before publishing the public key.
Key preparation is separate from pending request receipts and never removes them.
""".
-spec prepare(binary(), non_neg_integer()) -> {ok, <<_:256>>} | {error, term()}.
prepare(AgentRef, Epoch) -> prepare(AgentRef, Epoch, quod_time:mono_ms() + 5000).

-doc "Prepare within the caller's original absolute monotonic deadline.".
-spec prepare(binary(), non_neg_integer(), integer()) -> {ok, <<_:256>>} | {error, term()}.
prepare(AgentRef, Epoch, Deadline)
  when is_integer(Epoch), Epoch >= 0, Epoch < (1 bsl 64), is_integer(Deadline) ->
    call({prepare, AgentRef, Epoch, Deadline}, Deadline);
prepare(_, _, _) -> {error, invalid_preparation_epoch}.

-doc "Sign one typed canonical request after the governing bridge authorizes it.".
-spec sign(quod_client_goal:request(), integer()) -> {ok, binary(), <<_:512>>} | {error, term()}.
sign(Request, Deadline) when is_integer(Deadline) ->
    call({sign, Request, Deadline}, Deadline).

-doc "Delete local custody; durable key revocation remains an ordinary ontology action.".
-spec delete(binary(), <<_:256>>) -> ok | {error, term()}.
delete(AgentRef, PublicKey) -> call({delete, AgentRef, PublicKey}).

%% Scope is stable across executor/authority epochs; those belong in Receipt.
%% Only a newly retained receipt permits its caller's first submission.
retained(Scope) -> call({retained, Scope}).
retain(Scope, Receipt, Deadline) -> call({retain, Scope, Receipt, Deadline}, Deadline).
retire(Scope, Receipt) -> call({retire, Scope, Receipt}).

call(Request) -> call(Request, quod_time:mono_ms() + 5000).

call(Request, Deadline) ->
    case {quod_reg:where({agent_vault, node}), Deadline - quod_time:mono_ms()} of
        {undefined, _} -> {error, vault_unavailable};
        {_, Remaining} when Remaining =< 0 -> {error, deadline_exceeded};
        {Pid, Remaining} ->
            try gen_server:call(Pid, Request, Remaining)
            catch exit:{timeout, _} -> {error, deadline_exceeded};
                  exit:_ -> {error, vault_unavailable} end
    end.

init(#{directory := Directory, unlock_file := UnlockFile} = Config)
  when Directory =/= <<>>, Directory =/= [], UnlockFile =/= <<>>, UnlockFile =/= [] ->
    process_flag(trap_exit, true),
    stop_provider(),
    Dir = filename:absname(Directory),
    UnlockPath = filename:absname(UnlockFile),
    case lists:prefix(filename:split(Dir), filename:split(UnlockPath)) of
        true -> {stop, unlock_file_inside_vault};
        false ->
            case file:read_file_info(UnlockPath) of
                {ok, #file_info{type = regular, size = 32, mode = Mode}}
                  when Mode band 8#077 =:= 0 ->
                    case {file:read_file(UnlockPath), private_directory(Dir)} of
                        {{ok, <<_:256>> = Key}, ok} ->
                            case load_receipts(Dir) of
                                {ok, Receipts} ->
                                    case start_provider(maps:get(provider, Config, none)) of
                                        ok -> {ok, #s{directory = Dir,
                                            unlock = fun() -> Key end, receipts = Receipts}};
                                        {error, _} -> {stop, vault_provider_unavailable}
                                    end;
                                {error, _} -> {stop, vault_receipts_unavailable}
                            end;
                        _ -> {stop, vault_storage_unavailable}
                    end;
                _ -> {stop, vault_unlock_unavailable}
            end
    end;
init(_) -> {stop, invalid_vault_configuration}.

private_directory(Dir) ->
    case quod_file:ensure_parent(Dir) of
        ok ->
            case file:make_dir(Dir) of
                ok ->
                    case file:change_mode(Dir, 8#700) of
                        ok -> quod_file:sync_dir(filename:dirname(Dir));
                        Error -> Error
                    end;
                {error, eexist} ->
                    case file:read_file_info(Dir) of
                        {ok, #file_info{type = directory, mode = Mode}}
                          when Mode band 8#077 =:= 0 -> quod_file:sync_dir(Dir);
                        _ -> {error, insecure_vault_directory}
                    end;
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

handle_call({prepare, AgentRef, Epoch, Deadline}, _From, S)
  when is_integer(Epoch), Epoch >= 0, Epoch < (1 bsl 64), is_integer(Deadline) ->
    case Deadline > quod_time:mono_ms() of
        false -> {reply, {error, deadline_exceeded}, S};
        true ->
            {Result, Next} = custody_operation(S, fun() ->
                case identity(AgentRef) of
                    {ok, Network} -> prepare_key(Network, AgentRef, Epoch, S);
                    {error, _} = Error -> Error
                end
            end),
            Reply = case Deadline > quod_time:mono_ms() of
                true -> Result;
                false -> {error, deadline_exceeded}
            end,
            {reply, Reply, Next}
    end;
handle_call({sign, Request, Deadline}, _From, S) ->
    Result = within_deadline(Deadline,
        fun() -> secret_operation(fun() -> sign_request(Request, S) end) end),
    {reply, Result, S};
handle_call({delete, AgentRef, <<_:256>> = Pub}, _From, S) ->
    {Result, Next} = custody_operation(S, fun() -> case identity(AgentRef) of
        {ok, Network} ->
            case delete_preparation(Network, AgentRef, Pub, S) of
                ok -> delete_file(path(binding(Network, AgentRef, Pub), S));
                Error -> Error
            end;
        {error, _} = Error -> Error
    end end),
    {reply, Result, Next};
handle_call({retained, Scope}, _From, S) ->
    {Result, Next} = custody_operation(S, fun() -> receipt_lookup(Scope, S) end),
    {reply, Result, Next};
handle_call({retain, _, _, _} = Request, From, S = #s{sync_pending = true}) ->
    case custody_operation(S, fun() -> ok end) of
        {ok, Next} -> handle_call(Request, From, Next);
        {Error, Next} -> {reply, Error, Next}
    end;
handle_call({retain, Scope, Receipt, Deadline}, _From, S) ->
    case {Deadline > quod_time:mono_ms(), receipt_lookup(Scope, S)} of
        {false, _} -> {reply, {error, deadline_exceeded}, S};
        {true, {ok, Existing}} -> {reply, {ok, {existing, Existing}}, S};
        {true, none} ->
            case receipt_bytes(Scope, Receipt) of
                {ok, Bytes} ->
                    {Result, Next} = custody_operation(S, fun() ->
                        custody_mutation(fun() ->
                            quod_file:write_atomic(receipt_path(Scope, S#s.directory), Bytes, 8#600)
                        end)
                    end),
                    %% An ambiguous rename must retain the slot in memory too.
                    %% Its caller receives no permission to send on any error.
                    Retained = Next#s{receipts = (Next#s.receipts)#{Scope => Receipt}},
                    Reply = case {Result, Deadline > quod_time:mono_ms()} of
                        {ok, true} -> {ok, retained};
                        {ok, false} -> {error, deadline_exceeded};
                        {Error, _} -> Error
                    end,
                    {reply, Reply, Retained};
                Error -> {reply, Error, S}
            end;
        {true, Error} -> {reply, Error, S}
    end;
handle_call({retire, Scope, Receipt}, _From, S) ->
    case receipt_lookup(Scope, S) of
        {ok, Receipt} ->
            {Result, Next} = custody_operation(S,
                fun() -> delete_file(receipt_path(Scope, S#s.directory)) end),
            Retired = case Result of
                ok -> Next#s{receipts = maps:remove(Scope, Next#s.receipts)};
                _ -> Next
            end,
            {reply, Result, Retired};
        none -> {reply, ok, S};
        {ok, _Other} -> {reply, {error, stale_receipt}, S};
        Error -> {reply, Error, S}
    end;
handle_call(_Request, _From, S) -> {reply, {error, invalid_vault_request}, S}.

handle_cast(_Request, S) -> {noreply, S}.
handle_info(_Info, S) -> {noreply, S}.
terminate(_Reason, _S) -> stop_provider().
format_status(Status) -> Status#{state => encrypted_custody}.

%% Only a failed storage mutation can leave directory durability uncertain.
%% Resolve it once; refusing an unchanged request cannot schedule an fsync.
%% Startup also synchronizes the directory before accepting any requests.
custody_operation(S, Fun) ->
    Result = secret_operation(fun() ->
        case S#s.sync_pending of
            false -> Fun();
            true -> case custody_mutation(fun() -> quod_file:sync_dir(S#s.directory) end) of
                ok -> Fun();
                Error -> Error
            end
        end
    end),
    case Result of
        {uncertain_custody, Error} -> {Error, S#s{sync_pending = true}};
        _ -> {Result, S#s{sync_pending = false}}
    end.

custody_mutation(Fun) ->
    case secret_operation(Fun) of
        ok -> ok;
        {error, _} -> {uncertain_custody, {error, vault_storage_unavailable}}
    end.

within_deadline(Deadline, Fun) ->
    case Deadline > quod_time:mono_ms() of
        false -> {error, deadline_exceeded};
        true ->
            Result = Fun(),
            case Deadline > quod_time:mono_ms() of
                true -> Result;
                false -> {error, deadline_exceeded}
            end
    end.

start_provider(none) -> ok;
start_provider(#{ip := Ip, port := Port, peer_keys := Peers,
                 tls := #{certfile := Cert, keyfile := Key,
                          client_ca_file := CA} = TLS})
  when is_list(Peers), Peers =/= [], Cert =/= <<>>, Key =/= <<>>, CA =/= <<>> ->
    case lists:all(fun(Peer) -> is_binary(Peer) andalso byte_size(Peer) =:= 32 end, Peers) of
        true ->
            case quod_http_listener:start(
                   #{name => ?LISTENER, ip => Ip, port => Port, tls => TLS,
                     routes => [{'_', [{"/read", quod_client_http, {vault_read, Peers}}]}]}) of
                {ok, started} -> ok;
                _ -> {error, provider_start_failed}
            end;
        false -> {error, invalid_provider_peers}
    end;
start_provider(_) -> {error, invalid_provider_configuration}.

stop_provider() ->
    case whereis(ranch_sup) of
        undefined -> ok;
        _ -> quod_http_listener:stop(?LISTENER)
    end.

identity(AgentRef) ->
    case quod_agent_ref:decode(AgentRef) of
        {ok, _} ->
            case quod_ontology:network_identity() of
                {ok, Network} -> {ok, Network};
                _ -> {error, network_identity_unavailable}
            end;
        {error, _} -> {error, invalid_agent_reference}
    end.

sign_request(Request, S) ->
    case quod_client_goal:encode(Request) of
        {ok, Bytes} -> sign_canonical(Request, Bytes, S);
        {error, _} = Error -> Error
    end.

sign_canonical(#{agent_namespace := Ns, agent_genesis_anchor := Anchor,
                 agent_instance_text := InstanceText, parser_version := Parser,
                 signing_public_key := Pub, network_identity := Network,
                 not_after_ms := Deadline, goal_text := GoalText}, Bytes, S) ->
    case {quod_ontology:network_identity(),
          quod_agent_ref:from_text(Ns, Anchor, InstanceText, Parser),
          quod_client_goal_parser:parse(GoalText, Parser),
          Deadline > quod_time:now_ms()} of
        {{ok, Network}, {ok, #{blob := AgentRef}}, {ok, _}, true} ->
            case read_custody(path(binding(Network, AgentRef, Pub), S), Network, AgentRef, S) of
                {ok, _, Pub, Key} -> {ok, Bytes, quod_identity:sign(Bytes, Key)};
                {error, _} = Error -> Error;
                _ -> {error, invalid_vault_key}
            end;
        {{ok, Other}, _, _, _} when Other =/= Network -> {error, wrong_network};
        {{error, _}, _, _, _} -> {error, network_identity_unavailable};
        {_, _, _, false} -> {error, expired};
        _ -> {error, invalid_request}
    end.

encrypted_key(Network, AgentRef, Epoch, S) ->
    {Pub, Seed} = quod_identity:generate(),
    AAD = key_aad(Network, AgentRef, Pub, Epoch),
    IV = crypto:strong_rand_bytes(12),
    {Cipher, Tag} = crypto:crypto_one_time_aead(
                     aes_256_gcm, (S#s.unlock)(), IV, Seed, AAD, 16, true),
    {Pub, <<Epoch:64, Pub/binary, IV/binary, Tag/binary, Cipher/binary>>}.

read_custody(Path, Network, AgentRef, S) ->
    case file:read_file(Path) of
        {ok, <<Epoch:64, Pub:32/binary, IV:12/binary, Tag:16/binary, Cipher:32/binary>>} ->
            AAD = key_aad(Network, AgentRef, Pub, Epoch),
            case crypto:crypto_one_time_aead(
                   aes_256_gcm, (S#s.unlock)(), IV, Cipher, AAD, Tag, false) of
                <<_:256>> = Seed ->
                    case crypto:generate_key(eddsa, ed25519, Seed) of
                        {Pub, Seed} ->
                            {ok, Epoch, Pub, #{pubkey => Pub,
                                   key => quod_identity:key_term({Pub, Seed})}};
                        _ -> {error, invalid_vault_key}
                    end;
                error -> {error, invalid_vault_key}
            end;
        {error, enoent} -> {error, vault_key_unavailable};
        _ -> {error, invalid_vault_key}
    end.

key_aad(Network, AgentRef, Pub, Epoch) ->
    <<(binding(Network, AgentRef, Pub))/binary, Epoch:64>>.

prepare_key(Network, AgentRef, Epoch, S) ->
    Slot = preparation_path(Network, AgentRef, S),
    case read_custody(Slot, Network, AgentRef, S) of
        {ok, Previous, _, _} when Previous > Epoch -> {error, stale_preparation};
        {ok, Previous, Pub, _} ->
            case preserve_custody(Slot, path(binding(Network, AgentRef, Pub), S)) of
                ok when Previous =:= Epoch -> {ok, Pub};
                ok -> new_preparation(Slot, Network, AgentRef, Epoch, S);
                Error -> Error
            end;
        {error, vault_key_unavailable} -> new_preparation(Slot, Network, AgentRef, Epoch, S);
        Error -> Error
    end.

new_preparation(Slot, Network, AgentRef, Epoch, S) ->
    {Pub, Bytes} = encrypted_key(Network, AgentRef, Epoch, S),
    case custody_mutation(fun() -> quod_file:write_atomic(Slot, Bytes, 8#600) end) of
        ok ->
            case preserve_custody(Slot, path(binding(Network, AgentRef, Pub), S)) of
                ok -> {ok, Pub};
                Error -> Error
            end;
        Error -> Error
    end.

%% Both names reference one encrypted inode, not duplicate key records. The
%% slot is authoritative during preparation; the public-key name retains old
%% custody when a later epoch atomically replaces the bounded slot. A crash
%% before this link is installed is repaired by the next explicit preparation.
preserve_custody(Slot, KeyPath) ->
    case {file:read_file_info(Slot), file:read_file_info(KeyPath)} of
        {{ok, #file_info{inode = I, major_device = D}},
         {ok, #file_info{inode = I, major_device = D}}} when I =/= 0 -> ok;
        {{ok, _}, {error, enoent}} ->
            custody_mutation(fun() -> case file:make_link(Slot, KeyPath) of
                ok -> quod_file:sync_dir(filename:dirname(KeyPath));
                Error -> Error
            end end);
        {{ok, _}, {ok, _}} -> {error, conflicting_vault_custody};
        _ -> {error, vault_storage_unavailable}
    end.

preparation_path(Network, AgentRef, #s{directory = Dir}) ->
    Id = crypto:hash(sha256, <<Network/binary, AgentRef/binary>>),
    filename:join(Dir, "prepare-" ++ binary_to_list(binary:encode_hex(Id))).

delete_preparation(Network, AgentRef, Pub, S) ->
    Slot = preparation_path(Network, AgentRef, S),
    case read_custody(Slot, Network, AgentRef, S) of
        {ok, _, Pub, _} -> delete_file(Slot);
        {ok, _, _, _} -> ok;
        {error, vault_key_unavailable} -> ok;
        Error -> Error
    end.

delete_file(Path) ->
    custody_mutation(fun() -> case file:delete(Path) of
        ok -> quod_file:sync_dir(filename:dirname(Path));
        {error, enoent} -> quod_file:sync_dir(filename:dirname(Path));
        Error -> Error
    end end).

%% Startup is the only receipt scan. Ordinary lookups reuse this owner's map.
%% A corrupt retained slot fails closed instead of permitting a fresh request.
load_receipts(Dir) ->
    try
        {ok, Names} = file:list_dir(Dir),
        Receipts = lists:foldl(fun(Name, Acc) ->
            case lists:prefix("request-", Name) andalso filename:extension(Name) =/= ".tmp" of
                false -> Acc;
                true ->
                    Path = filename:join(Dir, Name),
                    {ok, Bytes} = file:read_file(Path),
                    {ok, {custody_receipt, 1, Scope, Receipt}} =
                        quod_safe_term:decode(Bytes, receipt_max_bytes()),
                    {ok, Bytes} = receipt_bytes(Scope, Receipt),
                    Path = receipt_path(Scope, Dir),
                    false = maps:is_key(Scope, Acc),
                    Acc#{Scope => Receipt}
            end
        end, #{}, Names),
        {ok, Receipts}
    catch _:_ -> {error, vault_storage_unavailable} end.

receipt_lookup(Scope = {<<_:256>>, ScopeBytes}, #s{receipts = Receipts}) when is_binary(ScopeBytes) ->
    case maps:find(Scope, Receipts) of {ok, R} -> {ok, R}; error -> none end;
receipt_lookup(_, _) -> {error, invalid_receipt_scope}.

receipt_bytes(Scope = {<<_:256>>, ScopeBytes}, Receipt = #{store := {B, <<_:512>>},
        request := {R, <<_:512>>}, fence := Fence, binding := Binding})
  when is_binary(ScopeBytes), is_binary(B), is_binary(R), is_binary(Fence), is_map(Binding) ->
    case {quod_client_goal:request_identity(B), quod_client_goal:request_identity(R),
          quod_durable_term:decode_goal(Fence)} of
        {{ok, _}, {ok, _}, {ok, _}} ->
            quod_safe_term:encode_canonical({custody_receipt, 1, Scope, Receipt}, receipt_max_bytes());
        _ -> {error, invalid_custody_receipt}
    end;
receipt_bytes(_, _) -> {error, invalid_custody_receipt}.

receipt_max_bytes() ->
    %% Two signed requests, one bounded retirement goal and two exact identities.
    2 * ?QUOD_CLIENT_GOAL_REQUEST_BYTES + 3 * ?QUOD_MAX_TOPLEVEL_GOAL_BYTES.

receipt_path(Scope, Dir) ->
    Id = crypto:hash(sha256, term_to_binary(Scope, [deterministic])),
    filename:join(Dir, "request-" ++ binary_to_list(binary:encode_hex(Id))).

binding(Network, AgentRef, Pub) ->
    <<?DOMAIN/binary, Network/binary, (crypto:hash(sha256, AgentRef))/binary, Pub/binary>>.

path(AAD, #s{directory = Dir}) ->
    filename:join(Dir, binary_to_list(binary:encode_hex(crypto:hash(sha256, AAD)))).

%% Crypto stack frames can contain key arguments. Redact at the custody
%% boundary; a backend error never becomes a secret-bearing process crash.
secret_operation(Fun) ->
    try Fun()
    catch error:_ -> {error, vault_operation_failed}
    end.
