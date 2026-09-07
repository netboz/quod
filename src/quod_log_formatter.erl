-module(quod_log_formatter).

-moduledoc """
OTP `m:logger` formatter that emits **one JSON object per log event** to
stdout, so the promtail `{job="docker"}` scrape already running on the qengho
cluster ships structured lines that Loki's `| json` parser splits into
queryable fields (`level`, `msg`, `node_id`, `mfa`, ...). Logs emitted inside
a sampled span also carry `otel_trace_id` and `otel_span_id`, allowing Grafana
to jump from a log line to the matching Tempo trace.

One line per event:

```json
{"ts":"2026-07-11T10:51:20.813456Z","level":"warning",
 "msg":"quod[quod:root]: catch-up attempt inconclusive (gap) — retrying",
 "node_id":"kp_f356f208","mfa":"quod_catchup:pull/2","line":88}
```

## Rules

- `msg` is truncated at 4096 bytes before encoding — BEAM crash reports can
  exceed Loki's `max_line_size`, and a dropped line helps no one.
- Private-key records and labelled secret fields are removed from structured
  reports, arguments and metadata BEFORE rendering. TLS libraries still need
  raw key terms even though Quod's loaded node identity is an opaque handle.
  Stack frames retain module/function/arity/location, never argument values.
  This cannot recover secrecy from an already-formatted string: callers must
  never interpolate secrets before submitting a logger event.
- `ts` is ISO-8601 UTC, microsecond precision, from the event's own `time`.
- Metadata that is not JSON-safe (pids, refs, ports, funs, non-UTF-8 binaries)
  round-trips through `~p`, so the formatter can never crash the handler — a
  crashing formatter would take stdout down, which is the exact failure this
  module exists to prevent.

Wired as the `default` handler's formatter in `config/sys.config`; `node_id`
arrives via the primary logger metadata that `m:quod_app` stamps at boot.
""".

-export([format/2, redact/1]).

-define(MSG_MAX_BYTES, 4096).

-spec format(logger:log_event(), logger:formatter_config()) -> unicode:chardata().
format(#{level := Level, msg := RawMsg, meta := RawMeta}, _Config) ->
    Msg = redact(RawMsg),
    Meta = redact(RawMeta),
    %% Base fields win over metadata of the same name (merge Base last).
    Base = #{ts    => iso8601(maps:get(time, Meta, erlang:system_time(microsecond))),
             level => atom_to_binary(Level, utf8),
             msg   => truncate(render_msg(Msg))},
    Event = maps:merge(safe_meta(Meta), Base),
    [encode(Event, Base), $\n].

%% The same data-level sanitation is used by OTP status callbacks. Do not
%% stringify first: private records may sit inside state, child arguments,
%% exception stacks, dictionaries, map keys, or report metadata.
-spec redact(term()) -> term().
redact(Term) when is_tuple(Term), tuple_size(Term) > 0,
                  (element(1, Term) =:= 'ECPrivateKey' orelse
                   element(1, Term) =:= 'RSAPrivateKey' orelse
                   element(1, Term) =:= 'DSAPrivateKey' orelse
                   element(1, Term) =:= 'PrivateKeyInfo' orelse
                   element(1, Term) =:= 'OneAsymmetricKey' orelse
                   element(1, Term) =:= ed_pri) ->
    redacted_private_key;
redact({Module, Function, Args, Location})
  when is_atom(Module), is_atom(Function), length(Args) >= 0, is_list(Location) ->
    {Module, Function, length(Args), redact(Location)};
redact({Name, Value}) ->
    {redact(Name), redact_field(Name, Value)};
redact(Term) when is_tuple(Term) ->
    list_to_tuple([redact(Value) || Value <- tuple_to_list(Term)]);
redact(Term) when is_map(Term) ->
    maps:from_list([{redact(Name), redact_field(Name, Value)}
                   || {Name, Value} <- maps:to_list(Term)]);
redact([Head | Tail]) -> [redact(Head) | redact(Tail)];
redact(Term) -> Term.

redact_field(Name, Value) when is_atom(Name) ->
    redact_field(atom_to_binary(Name, utf8), Value);
redact_field(Name, Value) when is_binary(Name) ->
    %% No atom allocation from untrusted metadata names.
    case Name of
        <<"key">> -> redacted_private_key;
        <<"identity_key">> -> redacted_private_key;
        <<"private_key">> -> redacted_private_key;
        <<"privateKey">> -> redacted_private_key;
        <<"client_private_key">> -> redacted_private_key;
        <<"server_private_key">> -> redacted_private_key;
        <<"tls_private_key">> -> redacted_private_key;
        _ -> redact(Value)
    end;
redact_field(_Name, Value) -> redact(Value).

%% Encode, but never let a bad term crash the handler: fall back to a minimal
%% line that still carries ts/level and names the failure.
encode(Event, Base) ->
    try encode_json(Event)
    catch C:R ->
        Fallback = Base#{msg => iolist_to_binary(
                                  io_lib:format("log encode failure ~p:~p", [C, R]))},
        encode_json(Fallback)
    end.

%% `logger_std_h` ultimately writes through the release's standard-I/O device.
%% Keep that boundary ASCII-only: a deployed startup notice showed that one
%% release log path can rewrite a raw UTF-8 codepoint after JSON encoding as the
%% Erlang-only `\x{...}` notation, corrupting the line. JSON's standard
%% `\uXXXX` escapes preserve the exact Unicode message and remain valid through
%% every output-device encoding.
encode_json(Term) ->
    iolist_to_binary(json:encode(Term, fun encode_ascii/2)).

encode_ascii(Value, _Encode) when is_binary(Value) ->
    json:encode_binary_escape_all(Value);
encode_ascii(Value, Encode) ->
    json:encode_value(Value, Encode).

-spec render_msg(term()) -> binary().
render_msg({string, Str})              -> unicode:characters_to_binary(Str);
render_msg({report, Report})           -> iolist_to_binary(io_lib:format("~p", [Report]));
render_msg({Format, Args}) when is_list(Format) ->
    unicode:characters_to_binary(io_lib:format(Format, Args)).

-spec truncate(binary()) -> binary().
truncate(Bin) when byte_size(Bin) =< ?MSG_MAX_BYTES -> Bin;
truncate(Bin) ->
    Head = binary:part(Bin, 0, ?MSG_MAX_BYTES),
    Tail = iolist_to_binary(io_lib:format("...[+~p bytes]",
                                          [byte_size(Bin) - ?MSG_MAX_BYTES])),
    <<Head/binary, Tail/binary>>.

-spec iso8601(integer()) -> binary().
iso8601(Micro) ->
    {{Y, Mo, D}, {H, Mi, S}} = calendar:system_time_to_universal_time(Micro, microsecond),
    iolist_to_binary(
      io_lib:format("~4..0B-~2..0B-~2..0BT~2..0B:~2..0B:~2..0B.~6..0BZ",
                    [Y, Mo, D, H, Mi, S, Micro rem 1000000])).

%% Render every metadata value JSON-safe. `time` is dropped (serialized as `ts`).
-spec safe_meta(map()) -> map().
safe_meta(Meta) -> maps:fold(fun entry/3, #{}, Meta).

entry(time, _V, Acc)              -> Acc;
entry(K, V, Acc) when is_atom(K)  -> Acc#{atom_to_binary(K, utf8) => value(V)};
entry(K, V, Acc)                  -> Acc#{value(K) => value(V)}.

value(V) when is_binary(V) ->
    case unicode:characters_to_binary(V) of
        B when is_binary(B) -> B;
        _                   -> fallback(V)
    end;
value(V) when is_atom(V); is_number(V); is_boolean(V) -> V;
value({M, F, A}) when is_atom(M), is_atom(F), is_integer(A) ->
    iolist_to_binary(io_lib:format("~s:~s/~B", [M, F, A]));
value(V) when is_list(V) ->
    case io_lib:printable_unicode_list(V) of
        true  -> unicode:characters_to_binary(V);
        false -> fallback(V)
    end;
value(V) when is_map(V) -> maps:fold(fun entry/3, #{}, V);
value(V)                -> fallback(V).

fallback(V) -> iolist_to_binary(io_lib:format("~p", [V])).
