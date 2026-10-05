-module(quod_physics_native).
-moduledoc "Mechanical Rapier adapter. Native operations use dirty CPU schedulers.".
-on_load(init/0).
-export([available/0, load_error/0, new_world/3, install/2, step/1, sample/1, retire/1]).
init() ->
    %% Optional physics must not make an embedded-mode consensus node fail boot.
    %% Availability follows this one module-load result, including its cause.
    Result = erlang:load_nif(filename:join(code:priv_dir(quod), "native/quod_physics"), 0),
    persistent_term:put({?MODULE, load_result}, Result),
    ok.
available() -> persistent_term:get({?MODULE, load_result}) =:= ok.
load_error() -> persistent_term:get({?MODULE, load_result}).
new_world(_Allowances, _Dt, _Gravity) -> erlang:nif_error(nif_not_loaded).
install(_World, _Bodies) -> erlang:nif_error(nif_not_loaded).
step(_World) -> erlang:nif_error(nif_not_loaded).
sample(_World) -> erlang:nif_error(nif_not_loaded).
retire(_World) -> erlang:nif_error(nif_not_loaded).
