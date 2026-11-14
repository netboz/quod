Ns = <<"quod:names">>,
Anchor = quod_simplex:genesis_hash(Ns),
{ok, [#{'N' := Places}], _} = quod_prolog:prove_ro(Ns, {count, {'_'}, <<"place">>, {'_'}, {'N'}}),
{fail, _} = quod_prolog:prove_ro(<<"quod:root">>, {system_ontology, Ns, {'_'}}),
{ok, _, Height} = quod_prolog:execute(<<"quod:root">>, {assertz, {system_ontology, Ns, Anchor}}),
#{anchor => binary:encode_hex(Anchor), place_names => Places, root_height => Height}.
