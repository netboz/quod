-module(quod_app).
-moduledoc "quod application entry point.".

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    quod_sup:start_link().

stop(_State) ->
    ok.
