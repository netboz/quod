-module(quod_tx_view_ws).
-behaviour(cowboy_websocket).

-export([init/2, websocket_init/1, websocket_handle/2, websocket_info/2, terminate/3]).
-include("quod_ledger.hrl").

init(Req, _Opts) -> {cowboy_websocket, Req, #{}}.

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
    iolist_to_binary([<<"{\"tx_id\":\"">>, json(binary_to_list(Id)), <<"\",\"goal\":\"">>,
                      json(term(Goal)), <<"\",\"result\":\"">>, json(term(Result)),
                      <<"\",\"diff\":\"">>, json(term(Diff)), <<"\"}">>]).

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
json([C | Rest]) when C < 32 -> [io_lib:format("\\u~4.16.0B", [C]) | json(Rest)];
json([C | Rest]) -> [C | json(Rest)].
