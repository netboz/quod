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
  heights => [{Ns, catch quod_prolog:applied(Ns)} || Ns <- [Root, Space, User]]}.
