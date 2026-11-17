-module(quod_directory_shape).
-moduledoc "Shared bounded-value validation for directory facts and pages.".

-export([validate_hosted/1, valid_namespace/1]).

-include("quod_directory_limits.hrl").

validate_hosted(Hosted) when is_list(Hosted) ->
    validate_hosted(Hosted, #{}, []);
validate_hosted(_) -> error.

validate_hosted([], _Seen, Acc) -> {ok, lists:sort(Acc)};
validate_hosted(
  [Descriptor = {Namespace, _Anchor, _Role, _Source} | Rest], Seen, Acc) ->
    case valid_hosted(Descriptor) andalso not maps:is_key(Namespace, Seen) of
        true -> validate_hosted(
                  Rest, Seen#{Namespace => true}, [Descriptor | Acc]);
        false -> error
    end;
validate_hosted(_, _, _) -> error.

valid_namespace(Namespace) ->
    is_binary(Namespace) andalso byte_size(Namespace) > 0 andalso
        byte_size(Namespace) =< ?DIRECTORY_MAX_NAMESPACE_BYTES.

valid_hosted({Namespace, <<_:256>>, Role, Source})
  when (Role =:= validator orelse Role =:= observer),
       (Source =:= bootstrap orelse Source =:= system orelse Source =:= node) ->
    valid_namespace(Namespace);
valid_hosted(_) -> false.
