-module(quod_ontology_name).
-moduledoc """
Canonical conversion of written Prolog ontology names to their flat binary form.

Both inter-ontology asks and runtime directory queries use this module so the
accepted name grammar cannot drift between the two APIs.

A Prolog double-quoted namespace arrives as a character list, so valid Unicode
text is accepted here as well as the atom, binary, and structured `:` forms
used by Erlang callers.  This is one name grammar for consoles, policies, and
runtime APIs; callers do not need a console-specific representation.
""".

-export([flatten/1]).

-spec flatten(term()) -> binary() | error.
flatten(A) when is_atom(A) ->
    atom_to_binary(A, utf8);
flatten(B) when is_binary(B) ->
    B;
flatten(Text) when is_list(Text) ->
    try unicode:characters_to_binary(Text) of
        Binary when is_binary(Binary) -> Binary;
        _ -> error
    catch _:_ -> error
    end;
flatten({':', L, R}) ->
    case {flatten(L), flatten(R)} of
        {LB, RB} when is_binary(LB), is_binary(RB) ->
            <<LB/binary, ":", RB/binary>>;
        _ ->
            error
    end;
flatten(_) ->
    error.
