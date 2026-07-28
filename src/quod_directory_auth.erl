-module(quod_directory_auth).
-moduledoc """
Shared validation for exact network-directory allowlists.

The normalized form is `Namespace => #{NodeKey => true}` so authorization
checks remain constant-time in both the ETS owner and dissemination process.
""".

-export([normalize_allowlist/1, node_key_index/1, allowed/3,
         validate_namespaces/2, valid_namespace/1]).

-include("quod_directory_limits.hrl").

normalize_allowlist(Map) when is_map(Map) ->
    try
        Pairs =
            [{Ns, maps:from_keys(Keys, true)}
             || {Ns, Keys} <- maps:to_list(Map),
                valid_namespace(Ns), is_list(Keys),
                lists:all(fun valid_node_key/1, Keys)],
        case length(Pairs) =:= map_size(Map) of
            true -> {ok, maps:from_list(Pairs)};
            false -> {error, bad_allowlist}
        end
    catch
        _:_ -> {error, bad_allowlist}
    end;
normalize_allowlist(_) ->
    {error, bad_allowlist}.

allowed(NodeKey, Namespace, Allowlist) ->
    case maps:get(Namespace, Allowlist, undefined) of
        Keys when is_map(Keys) -> maps:is_key(NodeKey, Keys);
        _ -> false
    end.

node_key_index(Allowlist) ->
    maps:fold(
      fun(_Namespace, Keys, Acc) ->
          maps:fold(
            fun(NodeKey, true, KeysAcc) ->
                KeysAcc#{NodeKey => true}
            end, Acc, Keys)
      end, #{}, Allowlist).

validate_namespaces(Namespaces, MaxCount)
  when is_list(Namespaces), is_integer(MaxCount), MaxCount >= 0 ->
    case length(Namespaces) =< MaxCount of
        false ->
            error;
        true ->
            Unique = lists:usort(Namespaces),
            case length(Unique) =:= length(Namespaces)
                     andalso lists:all(fun valid_namespace/1, Unique) of
                true -> {ok, Unique};
                false -> error
            end
    end;
validate_namespaces(_, _) ->
    error.

valid_namespace(Namespace) ->
    is_binary(Namespace) andalso byte_size(Namespace) > 0 andalso
        byte_size(Namespace) =< ?DIRECTORY_MAX_NAMESPACE_BYTES.

valid_node_key(NodeKey) ->
    is_binary(NodeKey) andalso byte_size(NodeKey) =:= 32.
