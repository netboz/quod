Ns = <<"quod:names">>,
{ok, not_hosted} = quod_ontology:local_state(Ns),
File = list_to_binary(filename:join([code:priv_dir(quod), "ontologies", "quod_names.pl"])),
{ok, [#{'Anchor' := Anchor}], Height} = quod_prolog:execute(<<"quod:root">>,
    {create_ontology, Ns, [{source_file, File}, {terms, []}, {external_predicate_modules, []}], {'Anchor'}}),
#{anchor => binary:encode_hex(Anchor), root_height => Height}.
