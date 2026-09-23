-module(quod_agent_vault).
-moduledoc """
Node-local encrypted custody for ontology-backed agent keys.

The containing ontology owns assignments and active/revoked key state. This
service owns only secret files, bound to the network, exact agent reference and
public key. Its in-VM API is a trusted backend for the governed signing bridge;
it is not a public permission boundary. Requests use the existing signed-goal
schema and encoder. No arbitrary-byte signing operation exists.

The operator supplies a separate 32-byte unlock file outside the vault directory.
Only an opaque closure retains that material, as with `m:quod_identity`; this
prevents accidental diagnostic disclosure, not inspection by code inside the VM.
""".
-behaviour(gen_server).

-include_lib("kernel/include/file.hrl").

-export([start_link/0, start_link/1, generate/1, sign/2, delete/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, format_status/1]).

-record(s, {directory :: file:filename(), unlock :: fun(() -> binary())}).
-define(LISTENER, quod_agent_vault_listener).
-define(DOMAIN, <<"quod.agent.key.v1", 0>>).

start_link() ->
    case application:get_env(quod, agent_vault) of
        {ok, Config} -> start_link(Config);
        undefined -> ignore
    end.

-spec start_link(map()) -> gen_server:start_ret().
start_link(Config) -> gen_server:start_link(quod_reg:via({agent_vault, node}), ?MODULE, Config, []).

-doc "Generate encrypted staged custody bound to one exact agent reference.".
-spec generate(binary()) -> {ok, <<_:256>>} | {error, term()}.
generate(AgentRef) -> call({generate, AgentRef}).

-doc "Sign one typed canonical request after the governing bridge authorizes it.".
-spec sign(quod_client_goal:request(), integer()) -> {ok, binary(), <<_:512>>} | {error, term()}.
sign(Request, Deadline) when is_integer(Deadline) ->
    call({sign, Request, Deadline}, Deadline).

-doc "Delete local custody; durable key revocation remains an ordinary ontology action.".
-spec delete(binary(), <<_:256>>) -> ok | {error, term()}.
delete(AgentRef, PublicKey) -> call({delete, AgentRef, PublicKey}).

call(Request) -> call(Request, quod_time:mono_ms() + 5000).

call(Request, Deadline) ->
    case {quod_reg:where({agent_vault, node}), Deadline - quod_time:mono_ms()} of
        {undefined, _} -> {error, vault_unavailable};
        {_, Remaining} when Remaining =< 0 -> {error, deadline_exceeded};
        {Pid, Remaining} ->
            try gen_server:call(Pid, Request, Remaining)
            catch exit:_ -> {error, vault_unavailable} end
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
                            case start_provider(maps:get(provider, Config, none)) of
                                ok -> {ok, #s{directory = Dir, unlock = fun() -> Key end}};
                                {error, _} -> {stop, vault_provider_unavailable}
                            end;
                        _ -> {stop, vault_storage_unavailable}
                    end;
                _ -> {stop, vault_unlock_unavailable}
            end
    end;
init(_) -> {stop, invalid_vault_configuration}.

private_directory(Dir) ->
    case filelib:ensure_dir(Dir) of
        ok ->
            case file:make_dir(Dir) of
                ok -> file:change_mode(Dir, 8#700);
                {error, eexist} ->
                    case file:read_file_info(Dir) of
                        {ok, #file_info{type = directory, mode = Mode}}
                          when Mode band 8#077 =:= 0 -> ok;
                        _ -> {error, insecure_vault_directory}
                    end;
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

handle_call({generate, AgentRef}, _From, S) ->
    Result = secret_operation(fun() -> case identity(AgentRef) of
        {ok, Network} ->
            {Pub, Seed} = quod_identity:generate(),
            AAD = binding(Network, AgentRef, Pub),
            IV = crypto:strong_rand_bytes(12),
            {Cipher, Tag} = crypto:crypto_one_time_aead(
                             aes_256_gcm, (S#s.unlock)(), IV, Seed, AAD, 16, true),
            case quod_identity:write_atomic(path(AAD, S), <<IV/binary, Tag/binary, Cipher/binary>>, 8#600) of
                ok -> {ok, Pub};
                {error, _} -> {error, vault_storage_unavailable}
            end;
        {error, _} = Error -> Error
    end end),
    {reply, Result, S};
handle_call({sign, Request, Deadline}, _From, S) ->
    Result = case Deadline > quod_time:mono_ms() of
        true -> secret_operation(fun() -> sign_request(Request, S) end);
        false -> {error, deadline_exceeded}
    end,
    Reply = case Deadline > quod_time:mono_ms() of
        true -> Result;
        false -> {error, deadline_exceeded}
    end,
    {reply, Reply, S};
handle_call({delete, AgentRef, <<_:256>> = Pub}, _From, S) ->
    Result = case identity(AgentRef) of
        {ok, Network} ->
            case file:delete(path(binding(Network, AgentRef, Pub), S)) of
                ok -> ok;
                {error, enoent} -> ok;
                {error, _} -> {error, vault_storage_unavailable}
            end;
        {error, _} = Error -> Error
    end,
    {reply, Result, S};
handle_call(_Request, _From, S) -> {reply, {error, invalid_vault_request}, S}.

handle_cast(_Request, S) -> {noreply, S}.
handle_info(_Info, S) -> {noreply, S}.
terminate(_Reason, _S) -> stop_provider().
format_status(Status) -> Status#{state => encrypted_custody}.

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
            case read_key(binding(Network, AgentRef, Pub), Pub, S) of
                {ok, Key} -> {ok, Bytes, quod_identity:sign(Bytes, Key)};
                {error, _} = Error -> Error
            end;
        {{ok, Other}, _, _, _} when Other =/= Network -> {error, wrong_network};
        {{error, _}, _, _, _} -> {error, network_identity_unavailable};
        {_, _, _, false} -> {error, expired};
        _ -> {error, invalid_request}
    end.

read_key(AAD, Pub, S) ->
    case file:read_file(path(AAD, S)) of
        {ok, <<IV:12/binary, Tag:16/binary, Cipher:32/binary>>} ->
            case crypto:crypto_one_time_aead(
                   aes_256_gcm, (S#s.unlock)(), IV, Cipher, AAD, Tag, false) of
                <<_:256>> = Seed ->
                    case crypto:generate_key(eddsa, ed25519, Seed) of
                        {Pub, Seed} ->
                            {ok, #{pubkey => Pub,
                                   key => quod_identity:key_term({Pub, Seed})}};
                        _ -> {error, invalid_vault_key}
                    end;
                error -> {error, invalid_vault_key}
            end;
        {error, enoent} -> {error, vault_key_unavailable};
        _ -> {error, invalid_vault_key}
    end.

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
