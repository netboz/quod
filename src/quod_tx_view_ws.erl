-module(quod_tx_view_ws).
-behaviour(cowboy_websocket).

-export([init/2, websocket_init/1, websocket_handle/2, websocket_info/2, terminate/3]).
-include("quod_ledger.hrl").

%% Cap inbound frames (this endpoint reads nothing from clients, so anything large is abuse — an
%% uncapped frame would let one client buffer the connection process to OOM). `idle_timeout => infinity`
%% keeps a quiet ledger from closing the socket (which would reload the page and wipe its history); a real
%% TCP close is still detected and terminates the handler regardless.
init(Req, _Opts) ->
    {cowboy_websocket, Req, #{}, #{max_frame_size => 65536, idle_timeout => infinity}}.

websocket_init(State) ->
    [quod_reg:subscribe({committed, Ns}) || Ns <- quod_simplex:namespaces()],
    {ok, State}.

websocket_handle(_Frame, State) -> {ok, State}.
websocket_info({committed, Slot, #entry{} = Entry}, State) ->
    {reply, {text, event_json(Slot, Entry)}, State};
websocket_info(_Info, State) -> {ok, State}.

terminate(_Reason, _Req, _State) -> ok.

event_json(Slot, #entry{timestamp = Timestamp, data = Data}) ->
    Transactions = case quod_ledger:payload(Data) of
        {ok, Payload} -> join([transaction_json(T) || T <- Payload]);
        error -> <<>>
    end,
    iolist_to_binary([<<"{\"slot\":">>, integer_to_binary(Slot), <<",\"timestamp\":">>,
                      integer_to_binary(Timestamp), <<",\"transactions\":[">>, Transactions, <<"]}">>]).

transaction_json(#transaction{tx_id = Id, goal = Goal, result = Result, diff = Diff}) ->
    iolist_to_binary([<<"{\"tx_id\":\"">>, hex(Id), <<"\",\"goal\":\"">>,
                      json(term(Goal)), <<"\",\"result\":\"">>, json(term(Result)),
                      <<"\",\"diff\":\"">>, json(term(Diff)), <<"\"}">>]).

%% tx_id is raw bytes (phash2 ++ unique_integer), NOT text — hex it so the frame is always valid UTF-8
%% (binary_to_list would splice bytes 0x80-0xFF straight into a JSON text frame, which browsers reject
%% and then reload-loop).
hex(Id) -> binary:encode_hex(Id, lowercase).

term(Value) -> lists:flatten(io_lib:format("~0p", [Value])).
join([]) -> <<>>;
join([One]) -> One;
join([One | Rest]) -> [One, <<",">>, join(Rest)].
json([]) -> [];
json([$" | Rest]) -> [<<"\\\"">> | json(Rest)];
json([$\\ | Rest]) -> [<<"\\\\">> | json(Rest)];
json([$\n | Rest]) -> [<<"\\n">> | json(Rest)];
json([$\r | Rest]) -> [<<"\\r">> | json(Rest)];
json([$\t | Rest]) -> [<<"\\t">> | json(Rest)];
%% Escape controls AND any non-ASCII byte (>= 127) as \uXXXX: `term/1`'s ~0p can emit latin1 bytes
%% 0x80-0xFF raw, which would make the text frame invalid UTF-8 (codepoints > 255 are already \x{..}
%% escaped by ~0p, so they never reach here). This keeps every frame valid JSON/UTF-8.
json([C | Rest]) when C < 32; C >= 127 -> [io_lib:format("\\u~4.16.0B", [C]) | json(Rest)];
json([C | Rest]) -> [C | json(Rest)].
