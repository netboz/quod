-module(quod_resource_basis).
-moduledoc """
Local invalidation dependencies of a committed resource-policy evaluation.

These keys are not transaction read tokens or consensus selection authority.
Owners retain them with the selected resource state and supply changed fact,
predicate-registry and explicit input keys. Owner/engine replacement requires
a fresh selection; an unclassified observation conservatively retains a parent
fence. The synchronous evaluator must start a fresh proof, not resume an earlier
invocation whose native dispatches were outside this observation lifetime.
""".
-export([capture/2, affected/2, unknown/0]).
-export_type([basis/0]).
-type basis() :: #{term() => true}.

-doc "Capture failure and execution errors before disposing the observation set.".
-spec capture(tuple(), fun((tuple()) -> T)) ->
          {T | {error, {atom(), term(), list()}}, basis()}.
capture(Est, Evaluate) ->
    quod_observation:capture(Est, fun dependency_keys/1,
      fun(Observed) ->
          try Evaluate(Observed)
          catch Class:Reason:Stack -> {error, {Class, Reason, Stack}}
          end
      end).

-doc "Fence an interrupted evaluation whose observations were not returned.".
-spec unknown() -> basis().
unknown() -> #{parent => true}.

-doc "Test owner-supplied deltas; registry membership is separate from fact values.".
-spec affected(basis(), #{term() => term()}) -> boolean().
affected(Basis, Changed) ->
    maps:is_key(parent, Basis) orelse
        maps:fold(fun(Key, _, Found) -> Found orelse maps:is_key(Key, Changed) end,
                  false, Basis).

dependency_keys({fact, Functor}) -> [{fact, Functor}];
dependency_keys(predicate_registry) -> [predicate_registry];
dependency_keys({input, Key}) -> [{input, Key}];
dependency_keys({flag_lookup, Name}) -> [{flag_names, Name}];
dependency_keys({flag_value, '$quod_ctx', _}) -> [parent];
dependency_keys({flag_value, Name, _}) -> [{flag, Name}];
dependency_keys({native, Mod, Fun, Predicate}) ->
    case pure_native(Mod, Fun, Predicate) of
        true -> [];
        false -> [parent]
    end;
%% Every compiled entry is observed before it creates a continuation. Known
%% pure entries add no hidden inputs; an unknown entry has already fenced the
%% entire fresh evaluation, including its later continuations and failures.
dependency_keys(native_continuation) -> [];
dependency_keys(_) -> [parent].

%% Classify exact immutable native implementations, never editable predicate
%% names alone. I/O and unknown native modules remain conservative. These
%% operations use only their terms; nested interpreted calls remain observed.
pure_native(erlog_bips, prove_goal, Predicate) ->
    lists:member(Predicate,
      [{'=', 2}, {'\\=', 2}, {'@>', 2}, {'@>=', 2}, {'==', 2}, {'\\==', 2},
       {'@<', 2}, {'@=<', 2}, {arg, 3}, {copy_term, 2}, {functor, 3},
       {numbervars, 3}, {term_variables, 2}, {term_variables, 3}, {'=..', 2},
       {atom, 1}, {atomic, 1}, {compound, 1}, {integer, 1}, {float, 1},
       {number, 1}, {nonvar, 1}, {var, 1}, {atom_chars, 2}, {atom_codes, 2},
       {atom_length, 2}, {'is', 2}, {'>', 2}, {'>=', 2}, {'=:=', 2},
       {'=\\=', 2}, {'<', 2}, {'=<', 2},
       {fail_with_reason, 1}, {get_fail_reasons, 1}]);
pure_native(erlog_lib_lists, Fun, Predicate) ->
    lists:member({Fun, Predicate},
      [{length_2, {length, 2}}, {append_3, {append, 3}},
       {insert_3, {insert, 3}}, {member_2, {member, 2}},
       {memberchk_2, {memberchk, 2}}, {reverse_2, {reverse, 2}},
       {sort_2, {sort, 2}}]);
pure_native(erlog_lib_dcg, expand_term_2, {expand_term, 2}) -> true;
pure_native(erlog_lib_dcg, phrase_3, {phrase, 3}) -> true;
pure_native(quod_common_primitives, binary_codes_2, {binary_codes, 2}) -> true;
pure_native(_, _, _) -> false.
