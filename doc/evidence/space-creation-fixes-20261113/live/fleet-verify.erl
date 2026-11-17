Space = <<"quod:space">>, Names = <<"quod:names">>,
P = fun(Ns, G) -> case quod_prolog:prove_ro(Ns, G) of {ok, [B], H} -> {ok, B, H}; Other -> Other end end,
#{names_hosted => lists:member(Names, quod_simplex:namespaces()),
  names_anchor => catch binary:encode_hex(quod_simplex:genesis_hash(Names)),
  place_names => P(Names, {count, {'_'}, <<"place">>, {'_'}, {'N'}}),
  name_default => P(Space, {have_attribute, space, name, binary, {'D'}}),
  free_place_rule => P(Space, {space_free_place, 0, 0, 0, -2250, 500, [{transform,0,0,-2250,0,0,0}], {'X'}}),
  heights => [{Ns, catch quod_prolog:applied(Ns)} || Ns <- [<<"quod:root">>, Names, Space]]}.
