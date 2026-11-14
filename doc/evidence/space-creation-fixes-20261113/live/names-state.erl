Ns = <<"quod:names">>,
Rows = quod_prolog:prove_ro(<<"quod:root">>, {findall, {'N'}, {system_ontology, {'N'}, {'_'}}, {'Rows'}}),
#{local_state => quod_ontology:local_state(Ns), catalogue => Rows,
  hosted => lists:member(Ns, quod_simplex:namespaces())}.
