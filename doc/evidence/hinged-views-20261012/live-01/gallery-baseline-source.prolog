'$quod_declared_class'(V0) :- '$quod_direct_isa'(V0, V1).
'$quod_declared_class'(V0) :- '$quod_direct_isa'(V1, V0).
'$quod_direct_isa'(V0, V1) :- clause(isa(V0, V1), V2) , \+ '$quod_isa_semantics'(V2) , call(V2).
'$quod_isa_path'(V0 : V1, V2, V3) :- V0 :: isa(V1, V4) , '$quod_qualified_class'(V0, V4, V5) , \+ member_eq(V5, V3) , V2 = V5.
'$quod_isa_path'(V0, V1, V2) :- '$quod_direct_isa'(V0, V1) , \+ member_eq(V1, V2).
'$quod_isa_path'(V0, V1, V2) :- '$quod_direct_isa'(V0, V3) , \+ member_eq(V3, V2) , '$quod_isa_path'(V3, V1, [V3 | V2]).
'$quod_isa_requires_closure'(V0, V1) :- var(V0).
'$quod_isa_requires_closure'(V0, V1) :- var(V1).
'$quod_isa_requires_closure'(V0, V1) :- \+ '$quod_direct_isa'(V0, V1).
'$quod_isa_semantics'('$quod_transitive_isa'(V0, V1)) :- true.
'$quod_isa_semantics'('$quod_known_class'(V0)) :- true.
'$quod_isa_semantics'((nonvar(V0) , V1 , '$quod_follow_unique'(V2))) :- true.
'$quod_known_class'(V0) :- nonvar(V0) , ! , ('$quod_direct_isa'(V0, V1) ; '$quod_direct_isa'(V2, V0)) , !.
'$quod_known_class'(V0) :- findall(V1, '$quod_declared_class'(V1), V2) , sort(V2, V3) , member(V0, V3).
'$quod_qualified_class'(V0, V1 : V2, V1 : V2) :- !.
'$quod_qualified_class'(V0, V1, V0 : V1) :- true.
'$quod_stricter_class'(V0, V1) :- member(V2, V1) , isa(V2, V0) , \+ isa(V0, V2).
'$quod_transitive_isa'(V0, V1) :- '$quod_isa_requires_closure'(V0, V1) , '$quod_direct_isa'(V0, V2) , \+ member_eq(V2, [V0]) , '$quod_isa_path'(V2, V1, [V2, V0]).
acceptance_actor(agent_instance_ref(<<"node:617e237fd538bc0f14e0d65389d9e2e9646bab3a16c782ab0a6d0900172f4d8e">>, <<"a\xBD\)\x95\\xAA\q\x18\\xB7\\xE3\\x1A\\xE3\\xA4\\xEE\\xA1\\x17\\xD8\~\xEA\Fy\x94\\x2\e\xB8\(\xE1\\x9A\\xB9\.#TW">>, me)) :- true.
acceptance_actor(agent_instance_ref(<<"node:e47cbf54a87f5c5add6c143671af90b72030ebfbd780819e682556a62b637016">>, <<"i\x9D\\xF1\\xC5\.\x89\\xA5\\xC\(e\x98\\x9F\\x90\\xC6\\x93\\x86\\x81\\x2\\x6\\x8D\aS\x81\K|H\xC9\\xB2\\x10\n\xF9\\xE3\">>, me)) :- true.
acceptance_actor(agent_instance_ref(<<"human:5pU3X8evhfH09g1ctl0LRRP80zmhd6M7g8OQ7DyOeaE">>, <<"u\x8F\\x8A\\xA1\=T\xCF\bk\xA4\\x93\\xA6\\xBF\\xBE\\xC2\EH\xAC\\x96\\xB4\\x9D\\xD0\\xFE\\xDA\;\xC0\\x84\>\x8\8\xCB\\xF2\">>, me)) :- true.
acceptance_authority_host(agent_instance_ref(<<"node:617e237fd538bc0f14e0d65389d9e2e9646bab3a16c782ab0a6d0900172f4d8e">>, <<"a\xBD\)\x95\\xAA\q\x18\\xB7\\xE3\\x1A\\xE3\\xA4\\xEE\\xA1\\x17\\xD8\~\xEA\Fy\x94\\x2\e\xB8\(\xE1\\x9A\\xB9\.#TW">>, me)) :- true.
action(initialize_agent_host(V0, V1, V2), [current_principal(V3), can_assign_agent_host(V3, V0, none, 0, V1, V2), agent_preparation_assignment(V0, none, 0), term_variables(V0, []), term_variables(V1, []), agent_identifier(V2)], agent_hosted(V0, V1, 1, V2)) :- true.
action(assign_agent_host(V0, V1, V2, V3, V4, V5), [term_variables(old(V1, V2), []), current_principal(V6), can_assign_agent_host(V6, V0, V1, V2, V3, V5), agent_hosted(V0, V1, V2, V7), integer(V2), V4 is V2 + 1, term_variables(V3, []), agent_identifier(V5), \+ agent_key(V0, V5, V8)], agent_assignment(V0, V1, V2, V3, V4, V5)) :- true.
action(begin_agent_recovery(V0, V1, V2, V3), [current_principal(V4), can_report_agent_failure(V4, V0, V1, begin), agent_hosted(V0, V1, V2, V5), \+ agent_recovery_round(V0, V6, V7, V8), agent_identifier(V3)], agent_recovery_current(V0, V1, V2, V3)) :- true.
action(resolve_agent_recovery(V0, V1, V2, V3), [term_variables(recovery(V0, V1, V2, V3), []), current_principal(V4), can_resolve_agent_recovery(V4, V0, V1, V2, V3), agent_recovery_current(V0, V1, V2, V3)], agent_recovery_resolved(V0, V1, V2, V3)) :- true.
action(prepare_agent_key(V0, V1, V2, V3, V4), [current_principal(V3), term_variables(old(V1, V2), []), integer(V2), V2 > 0, agent_key_preparation(V3, V0, V1, V2, V3), agent_identifier(V4), \+ agent_key(V0, V4, V5), \+ agent_candidate_key(V0, V1, V2, V3, V6)], agent_candidate_key(V0, V1, V2, V3, V4)) :- true.
action(report_agent_failure(V0, V1, V2, V3, observation(V4, V5, V6), V7), [current_principal(V8), can_report_agent_failure(V8, V0, V1, V7), agent_recovery_current(V0, V1, V2, V3), agent_identifier(V5), agent_observation_kind(V7), current_request_expiry(V6), agent_report_next(V0, V1, V2, V3, V8, V4)], agent_failure_report(V0, V1, V2, V3, V8, observation(V4, V5, V6), V7)) :- true.
agent_assignment(V0, V1, V2, V3, V4, V5) :- term_variables(old(V1, V2), []) , integer(V2) , V4 is V2 + 1 , agent_hosted(V0, V3, V4, V5).
agent_converge_candidate([], V0, V1, V2) :- true.
agent_converge_candidate([candidate(V0, V1, V2) | V3], V4, V5, V6) :- V7 is V6 + 1 , goal(agent_assignment(V4, V5, V6, V1, V7, V2)).
agent_failure_kind(process_down) :- true.
agent_failure_kind(suspected_unreachable) :- true.
agent_failure_support(V0, V1, V2, V3, V4, V5) :- agent_failure_kind(V5) , agent_report_support(V0, V1, V2, V3, V4, V5).
agent_host(physics_authority, agent_instance_ref(<<"node:617e237fd538bc0f14e0d65389d9e2e9646bab3a16c782ab0a6d0900172f4d8e">>, <<"a\xBD\)\x95\\xAA\q\x18\\xB7\\xE3\\x1A\\xE3\\xA4\\xEE\\xA1\\x17\\xD8\~\xEA\Fy\x94\\x2\e\xB8\(\xE1\\x9A\\xB9\.#TW">>, me), 1, <<"+uN,\xF9\\xE6\\xD0\$y\x98\\xB4\\xEE\\x9E\`a\x9B\\xE2\\xB\sh\xF5\\xA8\B\xFF\\x96\Q\xE6\Q\xDC\\xC4\\xC8\u">>) :- true.
agent_hosted(V0, V1, V2, V3) :- findall(host(V4, V5, V6), agent_host(V0, V4, V5, V6), [host(V1, V2, V3)]) , findall(V6, agent_key(V0, V6, active), [V3]).
agent_hosting_instances(keys(V0), V1, V0) :- true.
agent_hosting_instances(all, V0, V1) :- findall(V2, agent_host(V2, V0, V3, V4), V5) , sort(V5, V1).
agent_hosting_projection(V0, V1, V2, V3) :- agent_hosting_scope(V0, V2) , (V1 \= none -> agent_hosting_instances(V2, V1, V4) , findall(host(V5, V1, V6, V7), (member(V5, V4) , agent_hosted(V5, V1, V6, V7) , \+ agent_hosting_suspended(V5)), V3) ; V3 = []).
agent_hosting_scope(agent(V0), keys([V0])) :- true.
agent_hosting_scope(all, all) :- true.
agent_hosting_suspended(V0) :- fail.
agent_hosting_suspended(V0) :- physics_space(V1, V2, V0) , \+ physics_enabled(V1, V0).
agent_identifier(V0) :- binary_codes(V0, V1) , length(V1, 32).
agent_key(physics_authority, <<"+uN,\xF9\\xE6\\xD0\$y\x98\\xB4\\xEE\\x9E\`a\x9B\\xE2\\xB\sh\xF5\\xA8\B\xFF\\x96\Q\xE6\Q\xDC\\xC4\\xC8\u">>, active) :- true.
agent_key_preparation(V0, V1, V2, V3, V4) :- agent_preparation_assignment(V1, V2, V3) , can_prepare_agent_key(V0, V1, V2, V3, V4).
agent_observation_custody(prepared(V0), V1, V2, V3) :- current_principal(V4) , goal(agent_candidate_key(V1, V2, V3, V4, V0)).
agent_observation_custody(unavailable(V0), V1, V2, V3) :- true.
agent_observation_kind(process_down) :- true.
agent_observation_kind(suspected_unreachable) :- true.
agent_observation_kind(reachable) :- true.
agent_observation_kind(withdrawing) :- true.
agent_observation_round(none, V0, V1, V2, V3) :- \+ agent_recovery_round(V0, V4, V5, V6) , goal(agent_recovery_current(V0, V1, V2, V3)).
agent_observation_round(current(V0), V1, V2, V3, V0) :- agent_recovery_current(V1, V2, V3, V0).
agent_preparation_assignment(V0, none, 0) :- \+ agent_host(V0, V1, V2, V3) , \+ agent_key(V0, V4, V5).
agent_preparation_assignment(V0, V1, V2) :- integer(V2) , V2 > 0 , agent_hosted(V0, V1, V2, V3).
agent_recovery_current(V0, V1, V2, V3) :- agent_hosted(V0, V1, V2, V4) , findall(recovery(V5, V6, V7), agent_recovery_round(V0, V5, V6, V7), [recovery(V1, V2, V3)]).
agent_recovery_resolved(V0, V1, V2, V3) :- term_variables(recovery(V0, V1, V2, V3), []) , agent_hosted(V0, V1, V2, V4) , \+ agent_recovery_round(V0, V1, V2, V3).
agent_report_next(V0, V1, V2, V3, V4, V5) :- findall(V6, agent_failure_report(V0, V1, V2, V3, V4, V6, V7), V8) , agent_report_sequence(V8, V5).
agent_report_sequence([], 1) :- true.
agent_report_sequence([observation(V0, V1, V2)], V3) :- integer(V0) , V0 > 0 , V3 is V0 + 1.
agent_report_support(V0, V1, V2, V3, V4, V5) :- agent_observation_kind(V5) , agent_recovery_current(V0, V1, V2, V3) , current_request_expiry(V6) , agent_failure_report(V0, V1, V2, V3, V4, V7, V5) , findall(report(V8, V9), agent_failure_report(V0, V1, V2, V3, V4, V8, V9), [report(observation(V10, V11, V12), V5)]) , V6 =< V12.
agent_retract_matching(V0) :- findall(V0, V0, V1) , agent_retract_rows(V1).
agent_retract_rows([]) :- true.
agent_retract_rows([V0 | V1]) :- retract(V0) , agent_retract_rows(V1).
agent_work_after(start, V0) :- true.
agent_work_after(after(V0), V1) :- V1 @> V0.
assign_agent_host(V0, V1, V2, V3, V4, V5) :- agent_hosted(V0, V1, V2, V6) , retract(agent_host(V0, V1, V2, V6)) , retract(agent_key(V0, V6, active)) , assertz(agent_key(V0, V6, revoked)) , assertz(agent_key(V0, V5, active)) , assertz(agent_host(V0, V3, V4, V5)) , agent_retract_matching(agent_recovery_round(V0, V7, V8, V9)) , agent_retract_matching(agent_failure_report(V0, V10, V11, V12, V13, V14, V15)) , agent_retract_matching(agent_candidate_key(V0, V16, V17, V18, V19)).
begin_agent_recovery(V0, V1, V2, V3) :- assertz(agent_recovery_round(V0, V1, V2, V3)) , trigger_event(agent_recovery_started(V0, V1, V2, V3)).
can_admit_space_member(V0, V1, V2, V3) :- fail.
can_admit_space_member(room, agent_instance_ref(<<"node:e47cbf54a87f5c5add6c143671af90b72030ebfbd780819e682556a62b637016">>, <<"i\x9D\\xF1\\xC5\.\x89\\xA5\\xC\(e\x98\\x9F\\x90\\xC6\\x93\\x86\\x81\\x2\\x6\\x8D\aS\x81\K|H\xC9\\xB2\\x10\n\xF9\\xE3\">>, me), entity_ref(<<"acceptance:physics:259:04:objects">>, <<"V\xA3\5.-\xEC\\x7F\\xCE\X\xBD\M\x8D\3\x93\\x1A\U\xAD\T\x11\\xA\\xE0\U\xC7\\xCA\D\xA1\Y\xB\A\xC3\\xF9\v">>, obstacle), physical) :- true.
can_assign_agent_host(V0, physics_authority, none, 0, V0, V1) :- acceptance_authority_host(V0).
can_cancel_physics_activation(V0, V1) :- fail.
can_cancel_physics_door(V0, V1, V2) :- fail.
can_checkpoint_physics_body(V0, V1, V2) :- fail.
can_close_physics_door(V0, V1, V2) :- fail.
can_control_physics_agent(V0, V1, V2) :- fail.
can_delegate_physics_definition(V0, V1, V2, V3) :- fail.
can_edit_physics(V0, V1) :- fail.
can_edit_physics_definition(V0, V1) :- fail.
can_enter_space(V0, V1, V2, V3) :- fail.
can_invoke(V0, V1, [], V2) :- true.
can_invoke(V0, V1, V2, V3) :- acceptance_actor(V1).
can_invoke(physics_store_request(V0, V1, V2, V3, V4, V5), agent_instance_ref(<<"acceptance:physics:259:04:gallery">>, <<"A\xEF\\x1E\\x5\iC\xB6\)\xAC\\x1D\\xCA\q\xB1\;\xA0\\x2\\x8A\\xBD\\xE7\\xFB\{\xF\\x91\uf\x4\3J/\x7\\xB6\\x9B\">>, physics_authority), V6, <<"acceptance:physics:259:04:gallery">>) :- true.
can_invoke(physics_activate(V0, V1, V2), agent_instance_ref(<<"acceptance:physics:259:04:gallery">>, <<"A\xEF\\x1E\\x5\iC\xB6\)\xAC\\x1D\\xCA\q\xB1\;\xA0\\x2\\x8A\\xBD\\xE7\\xFB\{\xF\\x91\uf\x4\3J/\x7\\xB6\\x9B\">>, physics_authority), V3, <<"acceptance:physics:259:04:gallery">>) :- true.
can_leave_space(V0, V1, V2, V3) :- fail.
can_prepare_agent_key(agent_instance_ref(<<"node:617e237fd538bc0f14e0d65389d9e2e9646bab3a16c782ab0a6d0900172f4d8e">>, <<"a\xBD\)\x95\\xAA\q\x18\\xB7\\xE3\\x1A\\xE3\\xA4\\xEE\\xA1\\x17\\xD8\~\xEA\Fy\x94\\x2\e\xB8\(\xE1\\x9A\\xB9\.#TW">>, me), physics_authority, none, 0, agent_instance_ref(<<"node:617e237fd538bc0f14e0d65389d9e2e9646bab3a16c782ab0a6d0900172f4d8e">>, <<"a\xBD\)\x95\\xAA\q\x18\\xB7\\xE3\\x1A\\xE3\\xA4\\xEE\\xA1\\x17\\xD8\~\xEA\Fy\x94\\x2\e\xB8\(\xE1\\x9A\\xB9\.#TW">>, me)) :- true.
can_push_physics_body(V0, V1, V2) :- fail.
can_query_physics_motion(V0, V1, V2, V3) :- fail.
can_read_physics_body(V0, V1, V2) :- fail.
can_refresh_physics_definition(V0, V1, V2) :- fail.
can_refresh_physics_definition(room, agent_instance_ref(<<"node:e47cbf54a87f5c5add6c143671af90b72030ebfbd780819e682556a62b637016">>, <<"i\x9D\\xF1\\xC5\.\x89\\xA5\\xC\(e\x98\\x9F\\x90\\xC6\\x93\\x86\\x81\\x2\\x6\\x8D\aS\x81\K|H\xC9\\xB2\\x10\n\xF9\\xE3\">>, me), entity_ref(<<"acceptance:physics:259:04:objects">>, <<"V\xA3\5.-\xEC\\x7F\\xCE\X\xBD\M\x8D\3\x93\\x1A\U\xAD\T\x11\\xA\\xE0\U\xC7\\xCA\D\xA1\Y\xB\A\xC3\\xF9\v">>, obstacle)) :- true.
can_remove_space_member(V0, V1, V2, V3) :- fail.
can_remove_space_member(room, agent_instance_ref(<<"node:e47cbf54a87f5c5add6c143671af90b72030ebfbd780819e682556a62b637016">>, <<"i\x9D\\xF1\\xC5\.\x89\\xA5\\xC\(e\x98\\x9F\\x90\\xC6\\x93\\x86\\x81\\x2\\x6\\x8D\aS\x81\K|H\xC9\\xB2\\x10\n\xF9\\xE3\">>, me), entity_ref(<<"acceptance:physics:259:04:objects">>, <<"V\xA3\5.-\xEC\\x7F\\xCE\X\xBD\M\x8D\3\x93\\x1A\U\xAD\T\x11\\xA\\xE0\U\xC7\\xCA\D\xA1\Y\xB\A\xC3\\xF9\v">>, obstacle), physical) :- true.
can_request_agent_signature(agent_instance_ref(<<"node:617e237fd538bc0f14e0d65389d9e2e9646bab3a16c782ab0a6d0900172f4d8e">>, <<"a\xBD\)\x95\\xAA\q\x18\\xB7\\xE3\\x1A\\xE3\\xA4\\xEE\\xA1\\x17\\xD8\~\xEA\Fy\x94\\x2\e\xB8\(\xE1\\x9A\\xB9\.#TW">>, me), physics_authority, V0) :- true.
can_sign_agent_request(V0, V1, agent_goal_v1(V2, V3, V4, V5, V6, V7, V8, V9, V10)) :- V0 = V1 , V3 = agent_instance_ref(V11, V12, V13) , agent_hosted(V13, V1, V14, V5) , can_request_agent_signature(V0, V13, agent_goal_v1(V2, V3, V4, V5, V6, V7, V8, V9, V10)).
can_view_physics(V0, V1) :- fail.
class_eidolon(V0, prolog, source, recipe(V1, V2, prolog_editor)) :- nonvar(V0) , V1 = <<"quod:prolog:eidolons">> , quod : root :: system_ontology(V1, V2).
client_space_selection(V0, V1, V2) :- space_instance(V0, physical_space) -> (findall(V3, physics_client_view(V0, V1, V3), [V2]) -> true ; V2 = unavailable) ; current_principal(V4) , findall(V3, physics_control(V0, V4, V5, V3), V6) , (V6 = [] -> V2 = nonphysical ; V6 = [none] -> V2 = nonphysical ; V2 = unavailable).
client_view_dependencies([]) :- true.
client_view_dependencies([dependency(V0, V1, V2) | V3]) :- V0 :: current_ontology_identity(V0, V1) , client_view_dependencies(V3).
client_world_view(V0, V1, V2, world_view(entity_ref(V3, V4, V0), V5, V6)) :- term_variables([V0, V1, V2], []) , atom(V1) , client_view_dependencies(V2) , current_ontology_identity(V3, V4) , (space_instance(V0, space) , findall(V7, world_view(V0, V1, V7), [V5]) , term_variables(V5, []) , findall(ontology_ref(V8, V9), rendering_vocabulary(V8, V9), [ontology_ref(V10, V11)]) , V10 :: (current_ontology_identity(V10, V11) , well_formed_scene(V5)) -> client_space_selection(V0, V5, V6) ; V5 = [] , V6 = unavailable).
consensus_incarnation(<<"l\x4\h\xB\(\xB6\\x80\\xB8\!)\xC6\5\xFB\\x7\\\x\xAB\\x9C\\xEF\\xA3\S\xC4\\xD1\\xAD\\xB6\\x12\b\xF5\\xAC\\x1D\\xD4\\xE1\">>) :- true.
converge_agent_assignment(V0, V1, V2, V3) :- term_variables(recovery(V0, V1, V2, V3), []) , agent_recovery_current(V0, V1, V2, V3) , current_principal(V4) , findall(candidate(V5, V6, V7), (agent_candidate_key(V0, V1, V2, V6, V7) , \+ agent_key(V0, V7, V8) , agent_recovery_candidate(V4, V0, V1, V2, V3, V6, V5) , term_variables(candidate(V5, V6, V7), []) , can_assign_agent_host(V4, V0, V1, V2, V6, V7)), V9) , sort(V9, V10) , agent_converge_candidate(V10, V0, V1, V2).
delete(V0, V1, V2) :- insert(V2, V1, V0).
entity_eidolons(V0, V1) :- findall(V2, (instance_of(V2, V0) ; V2 = V0 , isa(V2, V2)), V3) , sort(V3, V4) , findall(eidolon(V5, V6, V7), (member(V2, V4) , class_eidolon(V2, V5, V6, V7)), V8) , sort(V8, V1).
external_predicate_modules([quod_agent_predicates(<<"H\xBD\\xB2\\x6\U\xD3\Q?h\x95\\xEF\\xCE\\x4\7P\x97\\x9B\\xB7\^\x15\\x9D\\x16\\xBC\\x96\\x9E\wcEf^`\\">>)]) :- true.
goal(V0) :- goal(V0, []).
goal(V0, V1) :- '$quod_callable'(V0) , resolve_goal(V0, V1).
initialize_agent_host(V0, V1, V2) :- assertz(agent_key(V0, V2, active)) , assertz(agent_host(V0, V1, 1, V2)).
instance_of(physical_space, room) :- true.
isa(V0, V0) :- '$quod_known_class'(V0).
isa(V0, V1) :- '$quod_transitive_isa'(V0, V1).
isa(space, thing) :- true.
isa(physical_space, space) :- true.
last(V0, V1) :- append(V2, [V1], V0).
member_eq(V0, [V1 | V2]) :- V0 == V1 , !.
member_eq(V0, [V1 | V2]) :- member_eq(V0, V2).
most_specific_classes(V0, V1, V2) :- term_variables(V0 - V1, []) , sort(V1, V3) , findall(V4, (member(V4, V3) , member(V5, V0) , isa(V5, V4)), V6) , sort(V6, V7) , findall(V4, (member(V4, V7) , \+ '$quod_stricter_class'(V4, V7)), V2).
ontology_eidolons(V0) :- findall(eidolon(V1, V2, V3), class_eidolon(ontology, V1, V2, V3), V4) , sort(V4, V0).
peer_admitted(<<"a~#\x7F\\xD5\8\xBC\\xF\\x14\\xE0\\xD6\S\x89\\xD9\\xE2\\xE9\dk\xAB\:\x16\\xC7\\x82\\xAB\\xA\m\x9\\x0\\x17\/M\x8E\">>, [49, 57, 50, 46, 49, 54, 56, 46, 49, 46, 49, 48], 25886, <<"a~#\x7F\\xD5\8\xBC\\xF\\x14\\xE0\\xD6\S\x89\\xD9\\xE2\\xE9\dk\xAB\:\x16\\xC7\\x82\\xAB\\xA\m\x9\\x0\\x17\/M\x8E\">>) :- true.
perm([], []) :- true.
perm([V0 | V1], V2) :- perm(V1, V3) , insert(V3, V0, V2).
phrase(V0, V1) :- phrase(V0, V1, []).
physics_absolute_input(reposition(V0), V1) :- physics_query_input(place(V0), V1, V1, V1).
physics_absolute_input(teleport(V0), V1) :- physics_query_vector(V0, V1).
physics_absolute_input(drive(V0, V1), V2) :- true.
physics_absolute_input(snap(V0), V1) :- true.
physics_activate(V0, V1, V2) :- transaction((physics_actor(V0) , physics_run(V0, V1, V3) , physics_request(V0, request(V2, V1, V4, V5)) , current_signed_request(V4, V5) , retract(physics_run(V0, V1, V3)) , V6 is V1 + 1 , assertz(physics_run(V0, V6, V2)))).
physics_activation_status(V0, V1, pending) :- physics_request(V0, V1) , V1 = request(V2, V3, V4, V5) , physics_run(V0, V3, V6).
physics_activation_status(V0, V1, activated) :- physics_request(V0, V1) , V1 = request(V2, V3, V4, V5) , V6 is V3 + 1 , physics_run(V0, V6, V2).
physics_activation_status(V0, V1, cancelled) :- physics_cancelled_request(V0, V1).
physics_active_selection(V0, V1, V2, V3) :- current_ontology_identity(V4, V5) , findall(V6, physics_structure(V0, V6), [V7]) , findall(run(V8, V9), physics_run(V0, V8, V9), V10) , findall(V11, agent_hosted(V1, V12, V11, V13), V14) , (V10 = [run(V15, V16)] , V14 = [V17] , V15 > 0 -> V3 = simulation_view(world_ref(V4, V5, V0), agent_instance_ref(V4, V5, V1), V17, V15, V16, V7, V2) ; (V10 = [] ; V10 = [run(0, none)] ; V14 = []) -> V3 = recovering ; V3 = unavailable).
physics_actor(V0) :- physics_enabled(V0, V1) , current_ontology_identity(V2, V3) , current_principal(agent_instance_ref(V2, V3, V1)) , agent_hosted(V1, V4, V5, V6).
physics_add_door(V0, V1, V2, V3, V4, V5) :- term_variables([V0, V1, V2, V3, V4, V5], []) , transaction((current_principal(V6) , can_edit_physics(V0, V6) , physics_structure(V0, V5) , V1 \= V2 , physics_reserve_body_ids(V0, [V1, V2]) , \+ physics_body_definition(V0, V1, V7, V8, V9, V10) , \+ physics_body_definition(V0, V2, V11, V12, V13, V14) , physics_door_definition(V3, door(V15, V16, V17, V18, V19)) , physics_valid_hinge_definition(V4, V15, V16) , physics_required_allowances(V0, limits(V20, V21, V22, V23, V24), V25, V26, V27) , physics_checked_body(V1, dynamic, V4, V16, V17, V23) , physics_checked_body(V2, fixed, V4, V15, V17, V23) , physics_valid_motor(V18, V19) , physics_body_capacity(V0, 2) , V28 is V5 + 1 , retract(physics_structure(V0, V5)) , assertz(physics_structure(V0, V28)) , assertz(physics_body_definition(V0, V2, V28, fixed, V4, owned(V15, V17))) , assertz(physics_body_definition(V0, V1, V28, dynamic, V4, owned(V16, V17))) , assertz(physics_joint(V0, hinge(V1, V28, V2, vector(0, 0, 0), V18, V19))) , assertz(physics_door_source(V0, V1, V3)) , assertz(physics_door(V0, V1, 0, idle)))).
physics_admission(V0, V1, V2, V3) :- fail.
physics_admission(room, entity_ref(<<"acceptance:physics:259:04:objects">>, <<"V\xA3\5.-\xEC\\x7F\\xCE\X\xBD\M\x8D\3\x93\\x1A\U\xAD\T\x11\\xA\\xE0\U\xC7\\xCA\D\xA1\Y\xB\A\xC3\\xF9\v">>, obstacle), fixed, vector(4000, 1000, 0)) :- true.
physics_advance_structure(V0, V1) :- findall(V2, physics_structure(V0, V2), [V3]) , V1 is V3 + 1 , retract(physics_structure(V0, V3)) , assertz(physics_structure(V0, V1)).
physics_agent(V0, V1, V2, V3, V4) :- fail.
physics_agent_configuration(V0, V1, V2, V3, V4) :- V4 = controlled_agent(V2, V5, V6, V7, V8, viewpoint(V3, V9, V10)) , can_control_physics_agent(V0, V1, V2) , once((instance_of(V11, V2) , (V11 = agent ; isa(V11, agent)))) , (findall(definition(V12, V13, V14), physics_agent(V0, V2, V12, V13, V14), [definition(V15, V16, V17)]) , findall(V18, physics_agent(V0, V18, V19, V16, V20), [V2]) , findall(V12, physics_body_definition(V0, V16, V12, V21, V22, V23), [V24]) , findall(mount(V13, V25, V26), physics_viewpoint(V0, V2, V3, V13, V25, V26), [mount(V16, V27, V28)]) -> true ; fail_with_reason(ambiguous_agent(V2))) , integer(V15) , V15 > 0 , term_variables([V2, V3, V16, V17, V27, V28], []) , V4 = controlled_agent(V2, V15, V16, V24, V17, viewpoint(V3, V27, V28)).
physics_allocate_body(V0, V1) :- physics_body_allocator(V0, V1) , physics_reserve_body_ids(V0, [V1]).
physics_allowances(room, limits(16, 16, 128, 1000000, geometry(32, 128, 128)), 16667, 0, 10000) :- true.
physics_allowed_input(drive(vector(V0, V1, V2), angular(V3, V4, V5)), V6, V7, V8, V9) :- physics_query_vector(vector(V0, V1, V2), V7) , physics_query_vector(vector(V3, V4, V5), V8) , V0 * V0 + V1 * V1 + V2 * V2 =< V7 * V7 , V3 * V3 + V4 * V4 + V5 * V5 =< V8 * V8 , (V6 = grounded(V10) -> V1 = 0 ; true).
physics_allowed_input(teleport(vector(V0, V1, V2)), grounded(V3), V4, V5, V6) :- integer(V0) , integer(V1) , integer(V2) , member(teleport(V7, V8, V9), V6) , physics_landing_parameters(V7, V8, V9).
physics_allowed_input(snap(V0), V1, V2, V3, V4) :- integer(V0) , member(snap(V5), V4) , integer(V5) , V5 > 0 , V5 =< 3141 , (V0 = V5 ; V0 =:= - V5).
physics_allowed_input(reposition(V0), V1, V2, V3, V4) :- member(reposition, V4).
physics_assign_authority(V0, V1, V2) :- term_variables([V0, V1, V2], []) , V1 \== V2 , transaction((current_principal(V3) , can_edit_physics(V0, V3) , findall(space(V4, V5), physics_space(V0, V4, V5), [space(V6, V1)]) , agent_hosted(V2, V7, V8, V9) , physics_run(V0, V10, V11) , physics_custody(V0, V12) , physics_previous_complete(V12, V10) , current_ontology_identity(V13, V14) , findall(live(V15, V16, V17, V18), physics_body_definition(V0, V19, V20, V21, V22, live(V15, V16, V17, V18)), V23) , retract(physics_space(V0, V6, V1)) , assertz(physics_space(V0, V6, V2)) , physics_redelegate_sources(V23, world_ref(V13, V14, V0), agent_instance_ref(V13, V14, V1), agent_instance_ref(V13, V14, V2)))).
physics_body_allocator(V0, V1) :- findall(V2, physics_next_body(V0, V2), [V1]) , integer(V1) , V1 >= 0 -> true ; fail_with_reason(body_allocator_missing(V0)).
physics_body_capacity(V0, V1) :- physics_required_allowances(V0, limits(V2, V3, V4, V5, V6), V7, V8, V9) , findall(V10, physics_body_definition(V0, V10, V11, V12, V13, V14), V15) , length(V15, V16) , (V16 + V1 =< V2 -> true ; fail_with_reason(body_allowance(V2))).
physics_body_coordinate(V0, V1) :- physics_milli_integer(V0) , (physics_coordinate(V0, V1) -> true ; fail_with_reason(coordinate_allowance(V1))).
physics_body_definition(V0, V1, V2, V3, V4, V5) :- fail.
physics_body_definition(room, 1, 1, fixed, vector(0, (-250), 0), owned(box(8000, 250, 8000), 1)) :- true.
physics_body_id_end([], V0, V0) :- true.
physics_body_id_end([V0 | V1], V2, V3) :- (integer(V0) , V0 >= V2 , V0 < 18446744073709551616 -> true ; fail_with_reason(body_identity_unavailable(V0))) , V4 is V0 + 1 , physics_body_id_end(V1, V4, V3).
physics_body_projection(V0, V1, physics_frame(world_ref(V2, V3, V0), agent_instance_ref(V2, V3, V4), V5, V6, V7, V8), V9) :- current_ontology_identity(V2, V3) , physics_enabled(V0, V4) , agent_hosted(V4, V10, V5, V11) , physics_run(V0, V6, V7) , V6 > 0 , physics_structure(V0, V8) , physics_body_definition(V0, V1, V9, V12, V13, V14).
physics_body_read_projection(V0, V1, V2, V3) :- current_principal(V4) , can_read_physics_body(V0, V4, V1) , physics_body_projection(V0, V1, V2, V3).
physics_body_vector(vector(V0, V1, V2), V3) :- physics_body_coordinate(V0, V3) , physics_body_coordinate(V1, V3) , physics_body_coordinate(V2, V3).
physics_cancel_activation(V0, V1, V2) :- term_variables([V0, V1, V2], []) , transaction((current_principal(V3) , can_cancel_physics_activation(V0, V3) , physics_run(V0, V1, V4) , V2 = request(V5, V1, V6, V7) , physics_custody(V0, V2) , retract(physics_request(V0, V2)) , assertz(physics_cancelled_request(V0, V2)))).
physics_cancel_door(V0, V1, V2) :- term_variables([V0, V1, V2], []) , transaction((current_principal(V3) , can_cancel_physics_door(V0, V1, V3) , retract(physics_door(V0, V1, V4, closing(V2))) , assertz(physics_door(V0, V1, V4, cancelled(V2))))).
physics_cancel_rest_edit(V0, V1) :- physics_rest_state(V0, V1, V2, V3) , (V3 = waiting(V4) -> physics_remove_rest_state(V0, V1) , assertz(physics_rest(V0, V1, V2, cancelled(V4))) ; true).
physics_checked_body(V0, V1, V2, V3, V4, V5) :- physics_valid_body(V0, V1, V2, V3, V4, V5) -> true ; fail_with_reason(invalid_physics_body(V0)).
physics_checkpoint_body(V0, V1, V2, V3, V4) :- term_variables([V0, V1, V2, V3, V4], []) , agent_identifier(V4) , transaction((current_principal(V5) , can_checkpoint_physics_body(V0, V1, V5) , physics_enabled(V0, V6) , (physics_free_body(V0, V1, V2) -> true ; fail_with_reason(body_not_free(V1))) , (physics_rest_policy(V0, V1, V7) -> true ; fail_with_reason(rest_policy_missing(V1))) , physics_rest_state(V0, V1, V8, V9) , (V3 = V8 -> true ; fail_with_reason(checkpoint_conflict(V1))) , (V9 \= waiting(V10) -> true ; fail_with_reason(checkpoint_pending(V1))) , physics_rest_custody(V0, V1, V11) , (physics_rest_replaceable(V11, V0, V1) -> true ; fail_with_reason(checkpoint_custody_held(V1))) , physics_remove_rest_state(V0, V1) , V12 is V3 + 1 , assertz(physics_rest(V0, V1, V12, waiting(rest(V12, V4)))) , physics_remove_rest_request(V0, V1))).
physics_client_control(V0, control(V1, controlled_agent(agent_instance_ref(V2, V3, V4), V5, V6, V7, V8, V9))) :- current_principal(V10) , can_view_physics(V0, V10) , current_ontology_identity(V2, V3) , physics_control_configuration(V0, V10, V1, controlled_agent(V4, V5, V6, V7, V8, V9)).
physics_client_view(V0, V1, V2) :- current_principal(V3) , physics_control_state(V0, V3, V4, V5) , physics_view_selection(V0, V3, V4, V5, V1, V2).
physics_close_door(V0, V1, V2, V3) :- term_variables([V0, V1, V2, V3], []) , agent_identifier(V3) , transaction((current_principal(V4) , can_close_physics_door(V0, V1, V4) , physics_door(V0, V1, V2, V5) , V5 \= closing(V6) , physics_enabled(V0, V7) , physics_joint(V0, hinge(V1, V8, V9, V10, V11, V12)) , retract(physics_door(V0, V1, V2, V5)) , V13 is V2 + 1 , assertz(physics_door(V0, V1, V13, closing(close(V13, V3)))) , physics_remove_door_request(V0, V1))).
physics_configuration_rows(V0, V1, V2, V3) :- findall(V0, V1, V3) , (V3 = [] -> fail_with_reason(V2) ; true).
physics_control(V0, V1, V2, V3) :- fail.
physics_control_agent(V0, V1, V2, V3) :- term_variables([V0, V1, V2, V3], []) , integer(V1) , V1 >= 0 , transaction((current_principal(V4) , physics_space(V0, V5, V6) , physics_control_state(V0, V4, V7, V8) , (V7 = V1 , V8 = V2 -> true ; fail_with_reason(control_conflict(V7))) , physics_control_choice(V0, V4, V3) , (V1 = 0 , V2 = none , \+ physics_control(V0, V4, V9, V10) -> true ; retract(physics_control(V0, V4, V1, V2))) , V11 is V1 + 1 , assertz(physics_control(V0, V4, V11, V3)))).
physics_control_choice(V0, V1, none) :- true.
physics_control_choice(V0, V1, controlled(V2, V3)) :- physics_agent_configuration(V0, V1, V2, V3, V4) , (\+ (physics_control(V0, V5, V6, controlled(V2, V7)) , V5 \== V1) -> true ; fail_with_reason(agent_controlled(V2))).
physics_control_configuration(V0, V1, V2, V3) :- physics_control_state(V0, V1, V2, controlled(V4, V5)) , integer(V2) , V2 > 0 , physics_agent_configuration(V0, V1, V4, V5, V3).
physics_control_state(V0, V1, V2, V3) :- findall(control(V4, V5), physics_control(V0, V1, V4, V5), V6) , (V6 = [] -> V2 = 0 , V3 = none ; V6 = [control(V4, V5)] -> V2 = V4 , V3 = V5 ; fail_with_reason(ambiguous_control(V0))).
physics_coordinate(V0, V1) :- physics_milli_integer(V0) , V0 >= - V1 , V0 =< V1.
physics_custody(V0, V1) :- findall(V2, physics_request(V0, V2), V3) , (V3 = [] -> V1 = none ; V3 = [V1]).
physics_definition(V0, V1, V2) :- fail.
physics_definition_allowance(V0, V1) :- fail.
physics_definition_consequence(V0, V1, V2, V3) :- findall(grant(V4, V5, V6), physics_definition_delegate(V0, V4, V5, V6), V7) , (V7 = [] -> true ; V7 = [grant(world_ref(V8, V9, V10), V11, V12)] , space_assignment(V0, V12, entity_ref(V8, V9, V10)) , current_ontology_identity(V13, V14) , V8 :: (current_ontology_identity(V8, V9) , physics_refresh_definition(V10, entity_ref(V13, V14, V0), V12, V1, V2, V3))).
physics_definition_delegate(V0, V1, V2, V3) :- fail.
physics_definition_projection(V0, V1, V2, V3, V4) :- V0 = world_ref(V5, V6, V7) , space_assignment(V2, V8, entity_ref(V5, V6, V7)) , findall(grant(V9, V10, V11), physics_definition_delegate(V2, V9, V10, V11), [grant(V0, V1, V8)]) , findall(definition(V11, V12), physics_definition(V2, V11, V12), [definition(V3, V4)]) , V4 = geometry(V13, V14).
physics_delegate_definition(V0, V1, V2, V3, V4, V5) :- term_variables([V0, V1, V2, V3], []) , transaction((current_principal(V6) , can_delegate_physics_definition(V0, V6, V1, V2) , V1 = world_ref(V7, V8, V9) , space_assignment(V0, V3, entity_ref(V7, V8, V9)) , \+ physics_definition_delegate(V0, V10, V11, V12) , assertz(physics_definition_delegate(V0, V1, V2, V3)) , physics_definition_projection(V1, V2, V0, V4, V5))).
physics_delete_definition(V0, V1) :- term_variables([V0, V1], []) , transaction((current_principal(V2) , can_edit_physics_definition(V0, V2) , findall(V3, physics_definition(V0, V1, V3), [V4]) , space_assignment(V0, V5, V6) , (V6 = none -> true ; space_withdraw(V0, V5, V6)) , retract(physics_definition(V0, V1, V4)) , V7 is V1 + 1 , assertz(physics_definition(V0, V7, none)))).
physics_dimension(V0, V1) :- physics_body_coordinate(V0, V1) , V0 > 0.
physics_door_custody(V0, V1, V2) :- findall(V3, physics_door_request(V0, V1, V3), V4) , (V4 = [] -> V2 = none ; V4 = [V2]).
physics_door_definition(local(V0, V1), V2) :- physics_door_class(V0, V1, V2).
physics_door_definition(class_ref(V0, V1, V2, V3), V4) :- V0 :: (current_ontology_identity(V0, V1) , physics_door_class(V2, V3, V4)).
physics_door_measurement(door_sample(V0, V1, V2, V3, V4, V5, V6, V7, V8, V9, V10, V11, V12, validity(V13, V14)), V15) :- physics_enabled(V0, V16) , current_ontology_identity(V17, V18) , V3 = agent_instance_ref(V17, V18, V16) , agent_hosted(V16, V19, V4, V20) , physics_run(V0, V5, V6) , physics_structure(V0, V7) , physics_door(V0, V1, V21, closing(V2)) , physics_body_definition(V0, V1, V8, dynamic, V22, V23) , physics_joint(V0, hinge(V1, V8, V24, V25, V26, motor(V27, V28, V29, V30))) , physics_body_definition(V0, V24, V9, fixed, V31, V32) , integer(V10) , V10 > 0 , V10 < 18446744073709551616 , integer(V11) , V11 >= - V26 , V11 =< V26 , physics_required_allowances(V0, V33, V34, V35, V36) , integer(V13) , integer(V14) , V14 > V13 , V14 - V13 =< V36 , current_request_expiry(V37) , V37 > V13 , V37 =< V14 , physics_door_result(V0, V1, V24, V11, V30, V12, V15).
physics_door_replaceable(none, V0) :- true.
physics_door_replaceable(request(V0, V1, V2, V3), V4) :- V0 = door_sample(V5, V6, V7, V8, V9, V10, V11, V12, V13, V14, V15, V16, V17, V18) , V4 = door_sample(V19, V20, V21, V22, V23, V24, V25, V26, V27, V28, V29, V30, V31, V32) , (V24 > V10 ; V24 = V10 , V29 > V15) , physics_request_rejected(V2, V3).
physics_door_result(V0, V1, V2, V3, V4, contact(V5, V6), blocked(V5)) :- V5 \= V1 , V5 \= V2 , physics_body_definition(V0, V5, V6, V7, V8, V9).
physics_door_result(V0, V1, V2, V3, V4, clear, closed) :- V3 >= - V4 , V3 =< V4.
physics_edit_definition(V0, V1, V2) :- term_variables([V0, V1, V2], []) , transaction((current_principal(V3) , can_edit_physics_definition(V0, V3) , findall(definition(V4, V5), physics_definition(V0, V4, V5), [definition(V1, V6)]) , V2 = geometry(V7, V8) , findall(V9, physics_definition_allowance(V0, V9), [V10]) , physics_checked_body(0, fixed, vector(0, 0, 0), V7, V8, V10) , V11 is V1 + 1 , retract(physics_definition(V0, V1, V6)) , assertz(physics_definition(V0, V11, V2)) , physics_definition_consequence(V0, V1, V11, V2))).
physics_enabled(V0, V1) :- physics_space(V0, enabled, V1) , space_instance(V0, physical_space) , findall(space(V2, V3), physics_space(V0, V2, V3), [space(enabled, V1)]) , physics_required_allowances(V0, V4, V5, V6, V7).
physics_finish_door(V0, V1) :- term_variables([V0, V1], []) , transaction((physics_door_measurement(V0, V1) , V0 = door_sample(V2, V3, V4, V5, V6, V7, V8, V9, V10, V11, V12, V13, V14, V15) , physics_actor(V2) , physics_door_request(V2, V3, request(V0, V1, V16, V17)) , current_signed_request(V16, V17) , retract(physics_door(V2, V3, V18, closing(V4))) , assertz(physics_door(V2, V3, V18, finished(V4, V1))) , physics_remove_door_checkpoint(V2, V3) , assertz(physics_checkpoint(V2, hinge(V3, V10, V7, V12, V13))) , trigger_event(physics_door_finished(V2, V3, V4, V1)))).
physics_finish_rest(V0) :- term_variables(V0, []) , transaction((physics_rest_measurement(V0) , V0 = rest_sample(V1, V2, V3, V4, V5, V6, V7, V8, V9, V10, V11, V12) , physics_actor(V1) , physics_rest_request(V1, V2, request(V0, rest, V13, V14)) , current_signed_request(V13, V14) , retract(physics_rest(V1, V2, V15, waiting(V3))) , assertz(physics_rest(V1, V2, V15, finished(V0))) , physics_remove_rest_checkpoint(V1, V2) , assertz(physics_checkpoint(V1, rest_v1(V2, V9, source(V4, V5, V6, V7, V8, V10), world_mm_quaternion_million, V11, zero_velocity))) , trigger_event(physics_body_checkpointed(V1, V2, V3)))).
physics_free_body(V0, V1, V2) :- physics_body_definition(V0, V1, V2, dynamic, V3, V4) , \+ physics_joint(V0, hinge(V1, V5, V6, V7, V8, V9)) , \+ physics_joint(V0, hinge(V10, V11, V1, V12, V13, V14)).
physics_input_control(V0, V1, V2, V3) :- physics_control_state(V0, V1, V4, V5) , (V5 = controlled(V6, V7) -> true ; fail_with_reason(no_control(V0))) , (V2 = V4 -> true ; fail_with_reason(control_conflict(V4))) , physics_agent_configuration(V0, V1, V6, V7, V3).
physics_input_limits(V0, V1, V2, V3, V4, V5, V6) :- V2 = controlled_agent(V7, V8, V9, V10, V11, V12) , V11 = motion(V13, V14, V15, V5, V6, V16) , physics_motion_mode(V13) , physics_motion_capabilities(V16, []) , integer(V14) , V14 > 0 , integer(V15) , V15 > 0 , integer(V5) , V5 > 0 , V6 = query_limits(V17, V18, V19, V20) , integer(V17) , V17 > 0 , integer(V18) , V18 >= 0 , V18 < V17 , integer(V19) , V19 > 0 , integer(V20) , V20 > 0 , physics_allowed_input(V4, V13, V14, V15, V16) , physics_required_allowances(V0, limits(V21, V22, V23, V24, V25), V26, V27, V28) , physics_absolute_input(V4, V24) , physics_body_projection(V0, V9, V3, V10) , physics_body_definition(V0, V9, V10, controlled, V29, V30).
physics_input_limits(V0, V1, V2, V3, push(body(V4, V5), vector(V6, V7, V8)), V9, push_limits(V4, V5, V10, V11)) :- V2 = controlled_agent(V12, V13, V14, V15, motion(V16, V17, V18, V9, V19, V20), V21) , integer(V9) , V9 > 0 , physics_push_configuration(V0, V1, V4, V5, V10, V11) , physics_query_vector(vector(V6, V7, V8), V10) , V6 * V6 + V7 * V7 + V8 * V8 > 0 , V6 * V6 + V7 * V7 + V8 * V8 =< V10 * V10 , physics_body_projection(V0, V4, V3, V5).
physics_input_projection(V0, control_frame(V1, V2), V3, V4, V5, V6, V7, V8) :- agent_identifier(V2) , integer(V4) , V4 >= 0 , current_principal(V9) , physics_input_control(V0, V9, V3, V10) , physics_input_limits(V0, V9, V10, V1, V5, V7, V8) , V6 = control(V9, V3, V10).
physics_landing_parameters(V0, V1, V2) :- integer(V0) , V0 > 0 , integer(V1) , V1 > 0 , integer(V2) , V2 > 0 , V2 =< 1000.
physics_milli_integer(V0) :- integer(V0) , physics_native_scalar_limit(V1) , V2 is V1 * 1000 , V0 >= - V2 , V0 =< V2.
physics_motion_capabilities([], V0) :- true.
physics_motion_capabilities([teleport(V0, V1, V2) | V3], V4) :- \+ member(teleport, V4) , physics_landing_parameters(V0, V1, V2) , physics_motion_capabilities(V3, [teleport | V4]).
physics_motion_capabilities([snap(V0) | V1], V2) :- \+ member(snap, V2) , integer(V0) , V0 > 0 , V0 =< 3141 , physics_motion_capabilities(V1, [snap | V2]).
physics_motion_capabilities([reposition | V0], V1) :- \+ member(reposition, V1) , physics_motion_capabilities(V0, [reposition | V1]).
physics_motion_mode(free) :- true.
physics_motion_mode(grounded(V0)) :- integer(V0) , V0 > 0 , V0 =< 1000.
physics_motion_read_projection(V0, V1, V2, V3, V4, query_limits(V5, V6, V7, V8)) :- current_principal(V9) , can_query_physics_motion(V0, V9, V1, V2) , physics_required_configuration(V10, physics_query_allowances(V0, V9, V10), query_allowances(V5, V6, V7, V8, V11, V12), query_allowances_missing(V0)) , integer(V5) , V5 > 0 , integer(V6) , V6 >= 0 , V6 < V5 , integer(V7) , V7 > 0 , integer(V8) , V8 > 0 , integer(V11) , V11 > 0 , integer(V12) , V12 > 0 , physics_required_allowances(V0, limits(V13, V14, V15, V16, V17), V18, V19, V20) , physics_query_input(V2, V16, V11, V12) , physics_body_projection(V0, V1, V3, V4).
physics_move_body(V0, V1, V2, V3, V4) :- term_variables([V0, V1, V2, V3, V4], []) , transaction((current_principal(V5) , can_edit_physics(V0, V5) , physics_structure(V0, V3) , physics_body_definition(V0, V1, V2, V6, V7, V8) , physics_resolve_definition(V0, V8, V9, V10) , \+ physics_joint(V0, hinge(V1, V11, V12, V13, V14, V15)) , \+ physics_joint(V0, hinge(V16, V17, V1, V18, V19, V20)) , physics_required_allowances(V0, limits(V21, V22, V23, V24, V25), V26, V27, V28) , V4 = vector(V29, V30, V31) , physics_relocated_pose(V7, V4, V32) , physics_checked_body(V1, V6, V32, V9, V10, V24) , V33 is V3 + 1 , retract(physics_structure(V0, V3)) , assertz(physics_structure(V0, V33)) , retract(physics_body_definition(V0, V1, V2, V6, V7, V8)) , assertz(physics_body_definition(V0, V1, V33, V6, V32, V8)) , physics_remove_rest_checkpoint(V0, V1) , physics_cancel_rest_edit(V0, V1))).
physics_move_door(V0, V1, V2, V3, V4) :- term_variables([V0, V1, V2, V3, V4], []) , transaction((current_principal(V5) , can_edit_physics(V0, V5) , physics_structure(V0, V3) , physics_door(V0, V1, V2, V6) , physics_joint(V0, hinge(V1, V7, V8, V9, V10, V11)) , physics_body_definition(V0, V1, V7, dynamic, V12, owned(V13, V14)) , physics_body_definition(V0, V8, V7, fixed, V15, owned(V16, V14)) , physics_required_allowances(V0, limits(V17, V18, V19, V20, V21), V22, V23, V24) , physics_valid_hinge_definition(V4, V16, V13) , physics_checked_body(V1, dynamic, V4, V13, V14, V20) , physics_checked_body(V8, fixed, V4, V16, V14, V20) , V25 is V3 + 1 , retract(physics_structure(V0, V3)) , assertz(physics_structure(V0, V25)) , retract(physics_body_definition(V0, V1, V7, dynamic, V12, owned(V13, V14))) , retract(physics_body_definition(V0, V8, V7, fixed, V15, owned(V16, V14))) , assertz(physics_body_definition(V0, V1, V25, dynamic, V4, owned(V13, V14))) , assertz(physics_body_definition(V0, V8, V25, fixed, V4, owned(V16, V14))) , retract(physics_joint(V0, hinge(V1, V7, V8, V9, V10, V11))) , assertz(physics_joint(V0, hinge(V1, V25, V8, V9, V10, V11))) , physics_remove_door_checkpoint(V0, V1) , retract(physics_door(V0, V1, V2, V6)) , (V6 = closing(V26) -> V27 = cancelled(V26) ; V27 = idle) , assertz(physics_door(V0, V1, V2, V27)))).
physics_native_scalar_limit(340282346638528859811704183484516925440) :- true.
physics_next_body(V0, V1) :- fail.
physics_next_body(room, 3) :- true.
physics_positive_scalar(V0) :- integer(V0) , V0 > 0 , physics_native_scalar_limit(V1) , V0 =< V1.
physics_previous_complete(none, V0) :- true.
physics_previous_complete(request(V0, V1, V2, V3), V4) :- V4 > V1.
physics_projection(V0, V1) :- findall(world(V2, V3, V4, V5, V6, V7, V8, V9, V10, V11, V12, V13, V14, baseline(V15, V16, V17, control_selection(V18, V19))), (physics_enabled(V2, V3) , agent_hosted(V3, V0, V4, V5) , physics_run(V2, V6, V7) , physics_structure(V2, V9) , physics_required_allowances(V2, V10, V11, V12, V14) , physics_custody(V2, V8) , findall(V20, physics_recovery_checkpoint(V2, V20), V15) , findall(V21, physics_joint(V2, V21), V16) , findall(door(V22, V23, V24, V25), (physics_door(V2, V22, V23, V24) , physics_door_custody(V2, V22, V25)), V26) , findall(rest(V22, V23, V24, V25), (physics_rest(V2, V22, V23, V24) , physics_rest_custody(V2, V22, V25)), V27) , append(V26, V27, V17) , findall(binding(V28, V29, V30), physics_control(V2, V28, V29, V30), V18) , findall(control(V28, V31, V32), (physics_control(V2, V28, V33, controlled(V34, V35)) , physics_control_configuration(V2, V28, V31, V32)), V36) , findall(push(V28, V37, V38, V39, V40), (physics_control(V2, V28, V41, controlled(V42, V43)) , physics_push_configuration(V2, V28, V37, V38, V39, V40)), V44) , append(V36, V44, V19) , findall(body(V45, V46, V47, V48, V49), physics_body_definition(V2, V45, V46, V47, V48, V49), V13)), V1).
physics_push_allowances(V0, V1, V2, V3) :- fail.
physics_push_configuration(V0, V1, V2, V3, V4, V5) :- can_push_physics_body(V0, V1, V2) , physics_free_body(V0, V2, V3) , physics_required_configuration(V6, physics_push_allowances(V0, V1, V2, V6), push_limits(V4, V5), push_allowances_missing(V2)) , integer(V4) , V4 > 0 , integer(V5) , V5 > 0.
physics_query_allowances(V0, V1, V2) :- fail.
physics_query_input(place(pose(V0, rotation(V1, V2, V3))), V4, V5, V6) :- physics_query_vector(V0, V4) , physics_query_vector(vector(V1, V2, V3), V6).
physics_query_input(travel(V0, angular(V1, V2, V3)), V4, V5, V6) :- physics_query_vector(V0, V5) , physics_query_vector(vector(V1, V2, V3), V6).
physics_query_input(landing(V0, V1, V2, V3), V4, V5, V6) :- physics_query_vector(V0, V4) , physics_landing_parameters(V1, V2, V3) , V1 =< V5 , V2 =< V5.
physics_query_vector(vector(V0, V1, V2), V3) :- physics_coordinate(V0, V3) , physics_coordinate(V1, V3) , physics_coordinate(V2, V3).
physics_recovery_checkpoint(V0, V1) :- physics_checkpoint(V0, V1) , V1 \= rest_v1(V2, V3, V4, V5, V6, V7).
physics_recovery_checkpoint(V0, rest(V1, V2)) :- physics_checkpoint(V0, V1) , V1 = rest_v1(V3, V4, V5, V6, V7, V8) , findall(V9, physics_rest_policy(V0, V3, V9), V10) , (V10 = [V2] -> true ; V2 = invalid).
physics_redelegate_definition(V0, V1, V2, V3, V4) :- term_variables([V0, V1, V2, V3, V4], []) , transaction((current_principal(V5) , can_delegate_physics_definition(V0, V5, V1, V3) , V1 = world_ref(V6, V7, V8) , space_assignment(V0, V4, entity_ref(V6, V7, V8)) , V6 :: (current_ontology_identity(V6, V7) , physics_world_authority(V8, V1, V3)) , findall(grant(V9, V10, V11), physics_definition_delegate(V0, V9, V10, V11), [grant(V1, V2, V4)]) , retract(physics_definition_delegate(V0, V1, V2, V4)) , assertz(physics_definition_delegate(V0, V1, V3, V4)))).
physics_redelegate_sources([], V0, V1, V2) :- true.
physics_redelegate_sources([live(entity_ref(V0, V1, V2), V3, V4, V5) | V6], V7, V8, V9) :- V0 :: (current_ontology_identity(V0, V1) , physics_redelegate_definition(V2, V7, V8, V9, V3)) , physics_redelegate_sources(V6, V7, V8, V9).
physics_refresh_definition(V0, V1, V2, V3, V4, V5) :- term_variables([V0, V1, V2, V3, V4, V5], []) , transaction((current_principal(V6) , can_refresh_physics_definition(V0, V6, V1) , space_placement(V0, V1, V2) , V4 is V3 + 1 , physics_world_authority(V0, V7, V8) , V1 = entity_ref(V9, V10, V11) , V9 :: (current_ontology_identity(V9, V10) , physics_definition_projection(V7, V8, V11, V4, V5)) , findall(body(V12, V13, V14, V15, V16), (physics_body_definition(V0, V12, V13, V14, V15, V16) , V16 = live(V1, V2, V3, V17)), [body(V18, V19, V20, V21, V22)]) , physics_unconstrained_body(V0, V18) , physics_required_allowances(V0, limits(V23, V24, V25, V26, V27), V28, V29, V30) , V5 = geometry(V31, V32) , physics_checked_body(V18, V20, V21, V31, V32, V26) , term_digest(V5, V33) , physics_advance_structure(V0, V34) , retract(physics_body_definition(V0, V18, V19, V20, V21, V22)) , assertz(physics_body_definition(V0, V18, V34, V20, V21, live(V1, V2, V4, V33))) , physics_remove_rest_checkpoint(V0, V18) , physics_cancel_rest_edit(V0, V18))).
physics_release_definition(V0, V1, V2) :- term_variables([V0, V1, V2], []) , transaction((V3 is V2 + 1 , space_assignment(V0, V3, none) , findall(V4, physics_definition_delegate(V0, V1, V4, V2), [V5]) , retract(physics_definition_delegate(V0, V1, V5, V2)))).
physics_relocated_pose(vector(V0, V1, V2), V3, V3) :- true.
physics_relocated_pose(pose(V0, V1), V2, pose(V2, V1)) :- true.
physics_removable_body(V0, V1) :- physics_unconstrained_body(V0, V1) , (\+ physics_agent(V0, V2, V3, V1, V4) -> true ; fail_with_reason(body_agent_binding(V1))) , physics_rest_custody(V0, V1, V5) , (V5 = none -> true ; V5 = request(V6, V7, V8, V9) , committed_operation_outcome(V8, V9, V10) , member(V10, [committed, rejected, aborted])).
physics_remove_door_checkpoint(V0, V1) :- findall(V2, (physics_checkpoint(V0, V2) , V2 = hinge(V1, V3, V4, V5, V6)), V7) , (V7 = [] -> true ; V7 = [V8] , retract(physics_checkpoint(V0, V8))).
physics_remove_door_request(V0, V1) :- physics_door_custody(V0, V1, V2) , (V2 = none -> true ; retract(physics_door_request(V0, V1, V2))).
physics_remove_rest_checkpoint(V0, V1) :- findall(V2, (physics_checkpoint(V0, V2) , V2 = rest_v1(V1, V3, V4, V5, V6, V7)), V8) , (V8 = [] -> true ; V8 = [V2] , retract(physics_checkpoint(V0, V2))).
physics_remove_rest_request(V0, V1) :- physics_rest_custody(V0, V1, V2) , (V2 = none -> true ; retract(physics_rest_request(V0, V1, V2))).
physics_remove_rest_state(V0, V1) :- findall(rest(V2, V3), physics_rest(V0, V1, V2, V3), V4) , (V4 = [] -> true ; V4 = [rest(V2, V3)] , retract(physics_rest(V0, V1, V2, V3))).
physics_request(room, request(<<"Y\xD9\\x9B\\x87\\x1F\\x1E\7\xE6\|6OC\x9C\\xE7\\x17\C\xEC\\xC3\GV\x18\\x13\p~;\xDB\\xD\\\\xC5\\x1B\d4">>, 5, <<"quod.agent.goal.v1\x0\\xE9\\xA4\\x85\\xA9\)\xBE\`]\xC0\\x1E\\x1B\\xBA\x \xAD\\x95\o\x84\\xDE\kP,$\xD1\\xB4\Z]H\x19\\x11\\x10\\x96\+uN,\xF9\\xE6\\xD0\$y\x98\\xB4\\xEE\\x9E\`a\x9B\\xE2\\xB\sh\xF5\\xA8\B\xFF\\x96\Q\xE6\Q\xDC\\xC4\\xC8\u\xB0\\\7\x1\\xC0\ns\x11\\x93\[}\xA8\XrY\xB0\\xB0\y\xE3\\x1B\;\xE8\?\xCD\\x4\\x88\|#\xA3\\x17\\xB3\\xA3\\x0\!acceptance:physics:259:04:galleryA\xEF\\x1E\\x5\iC\xB6\)\xAC\\x1D\\xCA\q\xB1\;\xA0\\x2\\x8A\\xBD\\xE7\\xFB\{\xF\\x91\uf\x4\3J/\x7\\xB6\\x9B\\x0\\x0\\x0\X'\\x70\\\\x68\\\\x79\\\\x73\\\\x69\\\\x63\\\\x73\\\\x5F\\\\x61\\\\x75\\\\x74\\\\x68\\\\x6F\\\\x72\\\\x69\\\\x74\\\\x79\\'.\x1\\x3\\x0\\x0\\x1\\xA1\0U4\x3\\x0\\x0\\x1\\x13\'\\x70\\\\x68\\\\x79\\\\x73\\\\x69\\\\x63\\\\x73\\\\x5F\\\\x61\\\\x63\\\\x74\\\\x69\\\\x76\\\\x61\\\\x74\\\\x65\\'('\\x72\\\\x6F\\\\x6F\\\\x6D\\',5,<<\"\\x59\\\\xD9\\\\x9B\\\\x87\\\\x1F\\\\x1E\\\\x37\\\\xE6\\\\x7C\\\\x36\\\\x4F\\\\x43\\\\x9C\\\\xE7\\\\x17\\\\x43\\\\xEC\\\\xC3\\\\x47\\\\x56\\\\x18\\\\x13\\\\x70\\\\x7E\\\\x3B\\\\xDB\\\\xD\\\\x5C\\\\xC5\\\\x1B\\\\x64\\\\x34\\\">>).">>, <<"\xB\X\x14\\xEE\\x0\\xEE\\xC4\\xE6\\x1E\\xD0\]h\xFC\\x80\i\x7\3\xD8\`\xBC\\x5\<\xB6\j^\xDD\%\xF3\~\xE6\\xD8\\x8A\ZE\xB7\\x90\\x8C\<6\x84\\xBE\]\xC0\\x5\\xB7\\xF2\\"\x91\u\xD6\\xDB\v\xA\\x0\Gx\xC5\9\xF4\_$x?\x2\">>)) :- true.
physics_request_rejected(V0, V1) :- committed_operation_outcome(V0, V1, V2) , (V2 = rejected ; V2 = aborted).
physics_required_allowances(V0, V1, V2, V3, V4) :- physics_configuration_rows(allowances(V5, V6, V7, V8), physics_allowances(V0, V5, V6, V7, V8), allowances_missing(V0), V9) , (V9 = [allowances(V1, V2, V3, V4)] -> true ; fail_with_reason(ambiguous_physics_configuration)).
physics_required_configuration(V0, V1, V2, V3) :- physics_configuration_rows(V0, V1, V3, V4) , member(V2, V4).
physics_reserve_body_ids(V0, V1) :- physics_body_allocator(V0, V2) , sort(V1, V3) , length(V1, V4) , length(V3, V4) , physics_body_id_end(V3, V2, V5) , retract(physics_next_body(V0, V2)) , assertz(physics_next_body(V0, V5)).
physics_resolve_definition(V0, owned(V1, V2), V1, V2) :- true.
physics_resolve_definition(V0, live(entity_ref(V1, V2, V3), V4, V5, V6), V7, V8) :- physics_world_authority(V0, V9, V10) , V1 :: (current_ontology_identity(V1, V2) , physics_definition_projection(V9, V10, V3, V5, geometry(V7, V8)) , physics_definition_delegate(V3, V9, V10, V4)) , term_digest(geometry(V7, V8), V6).
physics_rest(V0, V1, V2, V3) :- fail.
physics_rest_custody(V0, V1, V2) :- findall(V3, physics_rest_request(V0, V1, V3), V4) , (V4 = [] -> V2 = none ; V4 = [V3] -> V2 = V3 ; fail_with_reason(ambiguous_checkpoint_custody(V1))).
physics_rest_measurement(rest_sample(V0, V1, V2, V3, V4, V5, V6, V7, V8, V9, V10, validity(V11, V12))) :- physics_enabled(V0, V13) , current_ontology_identity(V14, V15) , V3 = agent_instance_ref(V14, V15, V13) , agent_hosted(V13, V16, V4, V17) , physics_run(V0, V5, V6) , physics_structure(V0, V7) , physics_free_body(V0, V1, V8) , physics_rest(V0, V1, V18, waiting(V2)) , physics_rest_policy(V0, V1, recovery(V19, V20)) , integer(V19) , V19 >= 0 , integer(V20) , V20 > 0 , physics_required_allowances(V0, limits(V21, V22, V23, V24, V25), V26, V27, V28) , V10 = pose(V29, quaternion(V30, V31, V32, V33)) , physics_query_vector(V29, V24) , physics_coordinate(V30, 1000000) , physics_coordinate(V31, 1000000) , physics_coordinate(V32, 1000000) , physics_coordinate(V33, 1000000) , V34 is V30 * V30 + V31 * V31 + V32 * V32 + V33 * V33 , V34 >= 999996000000 , V34 =< 1000004000000 , integer(V9) , V9 > 0 , V9 < 18446744073709551616 , integer(V11) , integer(V12) , V12 > V11 , V12 - V11 =< V28 , current_request_expiry(V35) , V35 > V11 , V35 =< V12 , \+ (physics_checkpoint(V0, rest_v1(V1, V36, source(V37, V38, V39, V40, V41, V42), V43, V44, V45)) , (V39 > V5 ; V39 = V5 , V42 >= V9)).
physics_rest_policy(V0, V1, V2) :- fail.
physics_rest_replaceable(none, V0, V1) :- true.
physics_rest_replaceable(request(V0, V1, V2, V3), V4, V5) :- (physics_rest(V4, V5, V6, finished(V0)) ; V0 = rest_sample(V4, V5, V7, V8, V9, V10, V11, V12, V13, V14, V15, V16) , physics_rest(V4, V5, V17, cancelled(V7)) , physics_free_body(V4, V5, V18) , V18 \= V13) -> true ; physics_request_rejected(V2, V3).
physics_rest_state(V0, V1, V2, V3) :- findall(rest(V4, V5), physics_rest(V0, V1, V4, V5), V6) , (V6 = [] -> V2 = 0 , V3 = idle ; V6 = [rest(V4, V5)] -> V2 = V4 , V3 = V5 ; fail_with_reason(ambiguous_checkpoint(V1))).
physics_run(room, 6, <<"Y\xD9\\x9B\\x87\\x1F\\x1E\7\xE6\|6OC\x9C\\xE7\\x17\C\xEC\\xC3\GV\x18\\x13\p~;\xDB\\xD\\\\xC5\\x1B\d4">>) :- true.
physics_selected_control(V0, V1, V2, none, none) :- true.
physics_selected_control(V0, V1, V2, controlled(V3, V4), control(V1, V2, V5)) :- physics_control_configuration(V0, V1, V2, V5).
physics_space(room, disabled, physics_authority) :- true.
physics_space_change(V0, V1, admitted) :- physics_enabled(V0, V2) , physics_world_authority(V0, V3, V4) , V1 = entity_ref(V5, V6, V7) , physics_subscription(V5, V6) , current_ontology_identity(V8, V9) , findall(admission(V10, V11), physics_admission(V0, V1, V10, V11), [admission(V12, V13)]) , \+ physics_body_definition(V0, V14, V15, V16, V17, live(V1, V18, V19, V20)) , V5 :: (current_ontology_identity(V5, V6) , space_assignment(V7, V21, entity_ref(V8, V9, V0)) , physics_delegate_definition(V7, V3, V4, V21, V22, geometry(V23, V24))) , term_digest(geometry(V23, V24), V25) , physics_required_allowances(V0, limits(V26, V27, V28, V29, V30), V31, V32, V33) , physics_body_capacity(V0, 1) , physics_allocate_body(V0, V34) , physics_checked_body(V34, V12, V13, V23, V24, V29) , physics_advance_structure(V0, V35) , assertz(physics_body_definition(V0, V34, V35, V12, V13, live(V1, V21, V22, V25))).
physics_space_change(V0, V1, withdrawn) :- current_ontology_identity(V2, V3) , V4 = world_ref(V2, V3, V0) , findall(body(V5, V6, V7, V8, V9), (physics_body_definition(V0, V5, V6, V7, V8, V9) , V9 = live(V1, V10, V11, V12)), [body(V13, V14, V15, V16, V17)]) , V17 = live(V1, V18, V19, V20) , V1 = entity_ref(V21, V22, V23) , physics_removable_body(V0, V13) , V21 :: (current_ontology_identity(V21, V22) , physics_release_definition(V23, V4, V18)) , physics_advance_structure(V0, V24) , retract(physics_body_definition(V0, V13, V14, V15, V16, V17)) , physics_remove_rest_checkpoint(V0, V13) , physics_remove_rest_state(V0, V13) , physics_remove_rest_request(V0, V13).
physics_store_door_request(V0, V1, V2, V3, V4) :- term_variables([V0, V1, V2, V3, V4], []) , transaction((physics_door_measurement(V0, V1) , V0 = door_sample(V5, V6, V7, V8, V9, V10, V11, V12, V13, V14, V15, V16, V17, V18) , physics_actor(V5) , physics_door_custody(V5, V6, V2) , physics_door_replaceable(V2, V0) , signed_physics_request(physics_finish_door(V0, V1), V3, V4) , physics_remove_door_request(V5, V6) , assertz(physics_door_request(V5, V6, request(V0, V1, V3, V4))))).
physics_store_request(V0, V1, V2, V3, V4, V5) :- transaction((physics_actor(V0) , physics_run(V0, V1, V6) , physics_custody(V0, V2) , physics_previous_complete(V2, V1) , agent_identifier(V3) , signed_physics_request(physics_activate(V0, V1, V3), V4, V5) , \+ physics_cancelled_request(V0, request(V3, V1, V4, V5)) , (V2 = none -> true ; retract(physics_request(V0, V2))) , assertz(physics_request(V0, request(V3, V1, V4, V5))))).
physics_store_rest_request(V0, V1, V2, V3) :- term_variables([V0, V1, V2, V3], []) , transaction((physics_rest_measurement(V0) , V0 = rest_sample(V4, V5, V6, V7, V8, V9, V10, V11, V12, V13, V14, V15) , physics_actor(V4) , physics_rest_custody(V4, V5, V1) , (V1 = none -> true ; V1 = request(V16, V17, V18, V19) , physics_request_rejected(V18, V19)) , signed_physics_request(physics_finish_rest(V0), V2, V3) , physics_remove_rest_request(V4, V5) , assertz(physics_rest_request(V4, V5, request(V0, rest, V2, V3))))).
physics_structure(room, 4) :- true.
physics_subscription(V0, V1) :- '$quod_predicate_source'(subscribes / 2, V2) , '$quod_program_source'(V3, V2) , member((subscribes(V4, V5) :- true), V3) , V4 == V0 , V5 == V1.
physics_unconstrained_body(V0, V1) :- \+ physics_joint(V0, hinge(V1, V2, V3, V4, V5, V6)) , \+ physics_joint(V0, hinge(V7, V8, V1, V9, V10, V11)) -> true ; fail_with_reason(body_constraint_group(V1)).
physics_valid_body(V0, V1, V2, V3, V4, V5) :- term_variables([V0, V1, V2, V3, V4, V5], []) , integer(V0) , V0 >= 0 , V0 < 18446744073709551616 , member(V1, [fixed, dynamic, controlled]) , physics_positive_scalar(V4) , integer(V5) , V5 > 0 , physics_valid_pose(V2, V5) , physics_valid_shape(V1, V3, V5).
physics_valid_hinge_definition(V0, V1, V2) :- V0 = vector(V3, V4, V5) , V1 = box(V6, V7, V8) , V2 = box(V9, V10, V11) -> true ; fail_with_reason(unsupported_hinge_definition).
physics_valid_motor(V0, motor(V1, V2, V3, V4)) :- integer(V0) , V0 > 0 , V0 < 3142 , physics_positive_scalar(V1) , physics_positive_scalar(V2) , physics_positive_scalar(V3) , integer(V4) , V4 > 0 , V4 < V0.
physics_valid_parts([], V0) :- true.
physics_valid_parts([part(V0, V1) | V2], V3) :- physics_valid_pose(V0, V3) , physics_valid_solid(V1, V3) , physics_valid_parts(V2, V3).
physics_valid_pose(vector(V0, V1, V2), V3) :- physics_body_vector(vector(V0, V1, V2), V3).
physics_valid_pose(pose(V0, rotation(V1, V2, V3)), V4) :- physics_body_vector(V0, V4) , physics_milli_integer(V1) , physics_milli_integer(V2) , physics_milli_integer(V3).
physics_valid_shape(V0, V1, V2) :- physics_valid_solid(V1, V2).
physics_valid_shape(V0, parts(V1), V2) :- V1 = [V3 | V4] , physics_valid_parts(V1, V2).
physics_valid_shape(fixed, surface(V0, V1), V2) :- V0 = [V3, V4, V5 | V6] , physics_valid_vertices(V0, V2) , length(V0, V7) , V1 = [V8 | V9] , physics_valid_triangles(V1, V7).
physics_valid_solid(box(V0, V1, V2), V3) :- physics_dimension(V0, V3) , physics_dimension(V1, V3) , physics_dimension(V2, V3).
physics_valid_solid(ball(V0), V1) :- physics_dimension(V0, V1).
physics_valid_solid(capsule(V0, V1), V2) :- physics_dimension(V0, V2) , physics_dimension(V1, V2).
physics_valid_solid(convex(V0), V1) :- V0 = [V2, V3, V4, V5 | V6] , physics_valid_vertices(V0, V1).
physics_valid_triangles([], V0) :- true.
physics_valid_triangles([triangle(V0, V1, V2) | V3], V4) :- physics_vertex_index(V0, V4) , physics_vertex_index(V1, V4) , physics_vertex_index(V2, V4) , V0 \= V1 , V1 \= V2 , V0 \= V2 , physics_valid_triangles(V3, V4).
physics_valid_vertices([], V0) :- true.
physics_valid_vertices([V0 | V1], V2) :- physics_body_vector(V0, V2) , physics_valid_vertices(V1, V2).
physics_vertex_index(V0, V1) :- integer(V0) , V0 >= 0 , V0 < 4294967296 , V0 < V1.
physics_view_bodies([], V0) :- true.
physics_view_bodies([mark(V0, V1, V2, V3, V4, V5, V6) | V7], V8) :- physics_view_body(V3, V6, V8) , physics_view_bodies(V7, V8).
physics_view_body(relative(V0, V1), V2, V3) :- physics_view_body(V1, V2, V3).
physics_view_body(transform(V0, V1, V2, V3, V4, V5), V6, V7) :- true.
physics_view_body(body_pose(V0, V1), depicts(V2, V3, V4), V5) :- physics_body_definition(V5, V0, V1, V6, V7, V8).
physics_view_selection(V0, V1, V2, V3, V4, V5) :- can_view_physics(V0, V1) -> (findall(space(V6, V7), physics_space(V0, V6, V7), [space(V8, V9)]) -> (V8 = disabled -> V5 = disabled ; V3 = controlled(V10, V11) , \+ can_control_physics_agent(V0, V1, V10) -> V5 = denied ; V8 = enabled , physics_enabled(V0, V9) , physics_view_bodies(V4, V0) , physics_selected_control(V0, V1, V2, V3, V12) -> physics_active_selection(V0, V9, V12, V5) ; V5 = unavailable) ; V5 = unavailable) ; V5 = denied.
physics_viewpoint(V0, V1, V2, V3, V4, V5) :- fail.
physics_world_authority(V0, world_ref(V1, V2, V0), agent_instance_ref(V1, V2, V3)) :- current_ontology_identity(V1, V2) , findall(V4, physics_space(V0, V5, V4), [V3]).
prepare_agent_and_converge(V0, V1, V2, V3, V4) :- term_variables(preparation(V0, V1, V2, V3, V4), []) , goal(agent_candidate_key(V0, V1, V2, V3, V4)) , (agent_recovery_current(V0, V1, V2, V5) -> converge_agent_assignment(V0, V1, V2, V5) ; true).
prepare_agent_key(V0, V1, V2, V3, V4) :- assertz(agent_candidate_key(V0, V1, V2, V3, V4)).
prolog_introspection(predicates, V0) :- findall(V1, current_predicate(V1), V2) , sort(V2, V0).
prolog_introspection(source(V0), V1) :- '$quod_predicate_source'(V0, V1).
prolog_introspection(chunks(V0), V1) :- '$quod_source_chunk'(V0, V1).
proof_draw(V0, V1, V2) :- '$quod_draw'(V0, V1, V2).
public_source_query(current_ontology_identity(V0, V1)) :- true.
public_source_query(ontology_eidolons(V0)) :- true.
public_source_query(entity_eidolons(V0, V1)) :- true.
react_on(observed(V0), physics_finish_door(V0, V1)) :- physics_observation(V0) , V0 = door_sample(V2, V3, V4, V5, V6, V7, V8, V9, V10, V11, V12, V13, V14, V15) , physics_door_measurement(V0, V1) , physics_door_custody(V2, V3, V16) , prepare_signed_request(V17, V18, physics_store_door_request(V0, V1, V16, V17, V18)).
react_on(observed(V0), physics_finish_rest(V0)) :- physics_observation(V0) , physics_rest_measurement(V0) , V0 = rest_sample(V1, V2, V3, V4, V5, V6, V7, V8, V9, V10, V11, V12) , physics_rest_custody(V1, V2, V13) , prepare_signed_request(V14, V15, physics_store_rest_request(V0, V13, V14, V15)).
report_agent_and_converge(V0, V1, V2, V3, V4, V5) :- term_variables(report(V0, V1, V2, V3, V4, V5), []) , current_principal(V6) , goal(agent_failure_report(V0, V1, V2, V3, V6, V4, V5)) , converge_agent_assignment(V0, V1, V2, V3).
report_agent_failure(V0, V1, V2, V3, V4, V5) :- current_principal(V6) , agent_retract_matching(agent_failure_report(V0, V1, V2, V3, V6, V7, V8)) , assertz(agent_failure_report(V0, V1, V2, V3, V6, V4, V5)) , trigger_event(agent_failure_observed(V0, V1, V2, V3, V6, V4, V5)).
report_agent_observation(V0, V1, V2, V3, V4, V5, V6) :- term_variables(report(V0, V1, V2, V3, V4, V5, V6), []) , agent_observation_round(V3, V0, V1, V2, V4) , report_agent_and_converge(V0, V1, V2, V4, V5, V6) , (agent_recovery_current(V0, V1, V2, V4) , current_principal(V7) , can_resolve_agent_recovery(V7, V0, V1, V2, V4) -> goal(agent_recovery_resolved(V0, V1, V2, V4)) ; true).
report_agent_observation_with_custody(V0, V1, V2, V3, V4, V5, V6, V7) :- term_variables(report(V0, V1, V2, V3, V4, V5, V6, V7), []) , agent_observation_custody(V7, V0, V1, V2) , report_agent_observation(V0, V1, V2, V3, V4, V5, V6).
resolve_agent_recovery(V0, V1, V2, V3) :- retract(agent_recovery_round(V0, V1, V2, V3)) , agent_retract_matching(agent_failure_report(V0, V1, V2, V3, V4, V5, V6)).
resolve_goal(V0, V1) :- '$quod_state_check'(V0) , !.
resolve_goal(V0, V1) :- \+ member_eq(V0, V1) , action(V2, V3, V0) , '$quod_action_shape'(V2, V3, V0) , '$quod_action_candidate'(V2, V3, V0, [V0 | V1]) , !.
run_declared_action(V0, V1) :- V2 = '$quod_stage_ontology'(V1, V0, V3) , action(V2, V4, V3) , '$quod_action_shape'(V2, V4, V3) , run_declared_candidate(V2, V4, V3).
run_declared_candidate(V0, V1, V2) :- '$quod_state_check'(V2) , !.
run_declared_candidate(V0, V1, V2) :- '$quod_action_candidate'(V0, V1, V2, [V2]).
run_transition([V0 | V1]) :- ! , call(V0) , run_transitions(V1).
run_transition(V0) :- call(V0).
run_transitions([]) :- true.
run_transitions([V0 | V1]) :- call(V0) , run_transitions(V1).
satisfy_prerequisites([], V0) :- true.
satisfy_prerequisites([goal(V0) | V1], V2) :- ! , goal(V0, V2) , satisfy_prerequisites(V1, V2).
satisfy_prerequisites([V0 :: goal(V1) | V2], V3) :- ! , V0 :: goal(V1, V3) , satisfy_prerequisites(V2, V3).
satisfy_prerequisites([V0 | V1], V2) :- '$quod_state_check'(V0) , satisfy_prerequisites(V1, V2).
space_accept_placement(V0, V1, V2) :- term_variables([V0, V1, V2], []) , V1 = entity_ref(V3, V4, V5) , transaction(((space_instance(V0, physical_space) -> true ; fail_with_reason(not_physical_space(V0))) , current_principal(V6) , current_ontology_identity(V7, V8) , can_admit_space_member(V0, V6, V1, physical) , V3 :: (current_ontology_identity(V3, V4) , space_assignment(V5, V2, entity_ref(V7, V8, V0))) , (\+ space_placement(V0, V1, V9) -> true ; fail_with_reason(space_placement_exists(V0, V1))) , space_change_physics(V0, V1, admitted) , assertz(space_placement(V0, V1, V2)))).
space_assignment(V0, V1, V2) :- findall(assignment(V3, V4), physical_assignment(V0, V3, V4), V5) , (V5 = [] -> V6 = 0 , V7 = none ; V5 = [assignment(V6, V7)] -> true ; fail_with_reason(ambiguous_space_assignment(V0))) , V1 = V6 , V2 = V7.
space_change_physics(V0, V1, V2) :- space_physical_change(V0, V1, V2) -> true ; fail_with_reason(space_physical_change_refused(V0, V2)).
space_consent(V0, V1, V2, V3) :- current_principal(V1) , space_subject(V0) , can_enter_space(V0, V1, V2, V3).
space_contain(V0, V1) :- term_variables([V0, V1], []) , V1 = entity_ref(V2, V3, V4) , transaction((space_instance(V0, space) , current_principal(V5) , current_ontology_identity(V6, V7) , V8 = entity_ref(V6, V7, V0) , V1 \== V8 , can_admit_space_member(V0, V5, V1, organizational) , V2 :: (current_ontology_identity(V2, V3) , space_consent(V4, V5, V8, organizational)) , \+ space_member(V0, V1) , assertz(space_member(V0, V1)))).
space_contains(V0, V1) :- space_member(V0, V1).
space_contains(V0, V1) :- space_placement(V0, V1, V2).
space_expected_assignment(V0, V1, V2) :- integer(V1) , V1 >= 0 , space_assignment(V0, V3, V4) , (V3 = V1 -> true ; fail_with_reason(space_revision_conflict(V0, V3))) , (V2 = V4 -> true ; fail_with_reason(space_destination_conflict(V0))).
space_instance(V0, V1) :- once((instance_of(V2, V0) , isa(V2, V1))).
space_physical_change(V0, V1, V2) :- fail.
space_physical_change(V0, V1, V2) :- physics_space_change(V0, V1, V2).
space_place(V0, V1, V2) :- term_variables([V0, V1, V2], []) , V2 = entity_ref(V3, V4, V5) , transaction((current_principal(V6) , instance_of(V7, V0) , can_enter_space(V0, V6, V2, physical) , space_expected_assignment(V0, V1, V8) , (V8 = none -> true ; fail_with_reason(space_already_placed(V0))) , current_ontology_identity(V9, V10) , V2 \== entity_ref(V9, V10, V0) , (V1 = 0 -> true ; retract(physical_assignment(V0, V1, none))) , V11 is V1 + 1 , assertz(physical_assignment(V0, V11, V2)) , V3 :: (current_ontology_identity(V3, V4) , space_accept_placement(V5, entity_ref(V9, V10, V0), V11)))).
space_release_placement(V0, V1, V2, V3) :- term_variables([V0, V1, V2, V3], []) , V1 = entity_ref(V4, V5, V6) , V3 is V2 + 1 , transaction((space_removal_allowed(V0, V1, physical) , V4 :: (current_ontology_identity(V4, V5) , space_assignment(V6, V3, none)) , space_change_physics(V0, V1, withdrawn) , retract(space_placement(V0, V1, V2)))).
space_removal_allowed(V0, V1, V2) :- current_principal(V3) , (can_remove_space_member(V0, V3, V1, V2) -> true ; V1 = entity_ref(V4, V5, V6) , current_ontology_identity(V7, V8) , V4 :: (current_ontology_identity(V4, V5) , space_withdrawal_consent(V6, V3, entity_ref(V7, V8, V0), V2))).
space_remove(V0, V1) :- term_variables([V0, V1], []) , transaction((space_removal_allowed(V0, V1, organizational) , retract(space_member(V0, V1)))).
space_subject(V0) :- once((instance_of(V1, V0) ; isa(V0, V0))).
space_withdraw(V0, V1, V2) :- term_variables([V0, V1, V2], []) , V2 = entity_ref(V3, V4, V5) , transaction((space_expected_assignment(V0, V1, V2) , retract(physical_assignment(V0, V1, V2)) , V6 is V1 + 1 , assertz(physical_assignment(V0, V6, none)) , current_ontology_identity(V7, V8) , V3 :: (current_ontology_identity(V3, V4) , space_release_placement(V5, entity_ref(V7, V8, V0), V1, V6)))).
space_withdrawal_consent(V0, V1, V2, V3) :- current_principal(V1) , can_leave_space(V0, V1, V2, V3).
subscribes(<<"acceptance:physics:259:04:objects">>, <<"V\xA3\5.-\xEC\\x7F\\xCE\X\xBD\M\x8D\3\x93\\x1A\U\xAD\T\x11\\xA\\xE0\U\xC7\\xCA\D\xA1\Y\xB\A\xC3\\xF9\v">>) :- true.
system_prolog_edit :- current_ontology_identity(V0, V1) , quod : root :: (current_ontology_identity(<<"quod:root">>, V2) , system_source_access(ontology_ref(V0, V1), editable)).
system_prolog_introspection(V0, V1) :- current_ontology_identity(V2, V3) , quod : root :: (current_ontology_identity(<<"quod:root">>, V4) , system_source_access(ontology_ref(V2, V3), V5)) , prolog_introspection(V0, V1).
system_source_query((current_ontology_identity(V0, V1) , system_prolog_introspection(V2, V3))) :- true.
system_source_query((current_ontology_identity(V0, V1) , system_prolog_edit , transaction(V2))) :- true.
