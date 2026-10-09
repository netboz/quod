-module(quod_physics_native).
-moduledoc "Mechanical Rapier adapter. Native operations use dirty CPU schedulers.".
-on_load(init/0).
-export([available/0, load_error/0, new_world/3, install/2, install_hinges/2, drive_hinge/3, hinge_samples/1, step/2, sample/1, retire/1]).
-export([motion_query/5,move_body/5,restore_rest/2,rest_sample/3,push_body/5]).
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
install_hinges(_World, _Hinges) -> erlang:nif_error(nif_not_loaded).
drive_hinge(_World, _Id, _Drive) -> erlang:nif_error(nif_not_loaded).
hinge_samples(_World) -> erlang:nif_error(nif_not_loaded).
step(_World, _Refresh) -> erlang:nif_error(nif_not_loaded).
sample(_World) -> erlang:nif_error(nif_not_loaded).
motion_query(_World, _Body, _Revision, _Query, _Limits) -> erlang:nif_error(nif_not_loaded).
move_body(_World, _Body, _Revision, _Query, _Limits) -> erlang:nif_error(nif_not_loaded).
retire(_World) -> erlang:nif_error(nif_not_loaded).

restore_rest(_World, _Rows) -> erlang:nif_error(nif_not_loaded).
rest_sample(_World, _Id, _Revision) -> erlang:nif_error(nif_not_loaded).
push_body(_World, _Id, _Revision, _Impulse, _MaxSpeed) -> erlang:nif_error(nif_not_loaded).
