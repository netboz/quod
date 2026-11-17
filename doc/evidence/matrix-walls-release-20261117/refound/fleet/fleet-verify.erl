Root = <<"quod:root">>, Space = <<"quod:space">>, User = <<"quod:user">>,
P = fun(Ns, G) -> case quod_prolog:prove_ro(Ns, G) of {ok, [B], _} -> {ok, B}; Other -> Other end end,
{ok, Height, Descriptors, Rejected} = quod_system_ontology:catalog(),
Systems = lists:sort([Ns || #{namespace := Ns} <- Descriptors]),
#{root_anchor => binary:encode_hex(quod_simplex:genesis_hash(Root)),
  catalogue_height => Height, systems => length(Systems), rejected => map_size(Rejected),
  not_ready => [Ns || Ns <- Systems, quod_ontology:local_state(Ns) =/= {ok, ready}],
  status => (fun(#{role := R, committee := C, syncing := Sy, committed := Co}) ->
                 #{role => R, committee_size => length(C), syncing => Sy, committed => Co} end)(quod_simplex:status(Root)),
  leave_to_parent => P(Space, {clause, {space_leave_to, {'_'}, {'_'}}, {'_'}}) =/= {fail, []},
  near => P(Space, {space_near, {'S'}, {'N'}}),
  personal_icons => P(User, {clause, {personal_menu_destination, {'_'}, {'_'}}, {'_'}}) =/= {fail, []},
  interior_eidolons => P(Space, {findall, {'N'}, {class_eidolon, space, interior, {'N'}, {'_'}}, {'L'}}),
  show_as => P(User, {clause, {show_as, {'_'}, {'_'}, {'_'}}, {'_'}}) =/= {fail, []},
  default_icon => P(<<"quod:gui">>, {gui_icon, default, {'_'}}) =/= {fail, []},
  matrix_rains => (fun({ok, #{'W' := Walls}}) -> string:find(io_lib:format("~0p", [Walls]), "rain") =/= nomatch; (_) -> false end)(
                     P(Space, {findall, {'X'}, {clause, {eidolon, space_matrix, {'_'}, {'X'}}, {'_'}}, {'W'}})),
  root_anchor_text => binary_to_list(binary:encode_hex(quod_simplex:genesis_hash(Root))),
  heights => [{Ns, catch quod_prolog:applied(Ns)} || Ns <- [Root, Space, User]]}.
