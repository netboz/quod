# Combined EUnit 02 failure inventory

4,370 tests; 126 failures; no cancellation. Source: `combined-eunit-02.log`.
Classification concerns the observed result; corrected tests must pass in their follow-up.

## 1) quod_physics_tests:-m3a_shared_component_test_/0-fun-49-/0

Log line 32532. Ordinary failure is bare fail; assertion still expects an automatic diagnostic.

```text
Failure/Error: ?assertMatch({ fail , _ }, quod_prolog : prove_ro ( Ns , { space_placement , room , Leaf , { '_' } } ))
```

## 2) quod_physics_tests:-m3a_shared_projection_test_/0-fun-25-/0

Log line 32541. Ordinary failure is bare fail; assertion still expects an automatic diagnostic.

```text
Failure/Error: ?assertMatch({ fail , _ }, quod_prolog : prove_ro ( Ns , { physics_body_definition , room , 4 , { '_' } , { '_' } , { '_' } , { '_' } } ))
```

## 3) quod_physics_tests:-first_host_and_complete_configuration_commit_together_test_/0-fun-4-/0: gallery-first-physics

Log line 32550. Ordinary failure is bare fail; assertion still expects an automatic diagnostic.

```text
Failure/Error: ?assertMatch({ fail , _ }, quod_prolog : prove_ro ( Ns , { agent_host , actor , { '_' } , { '_' } , { '_' } } ))
```

## 4) quod_physics_tests:-first_host_and_complete_configuration_commit_together_test_/0-fun-4-/0: workshop-first-physics

Log line 32559. Ordinary failure is bare fail; assertion still expects an automatic diagnostic.

```text
Failure/Error: ?assertMatch({ fail , _ }, quod_prolog : prove_ro ( Ns , { agent_host , actor , { '_' } , { '_' } , { '_' } } ))
```

## 5) quod_physics_tests:-live_source_lifecycle_test_/0-fun-21-/0: live-workshop

Log line 32568. Ordinary failure is bare fail; assertion still expects an automatic diagnostic.

```text
Failure/Error: ?assertMatch({ fail , _ }, quod_prolog : prove_ro ( Ns , { space_placement , room , Subject , { '_' } } ))
```

## 6) quod_physics_tests:-live_source_lifecycle_test_/0-fun-21-/0: live-observatory

Log line 32577. Ordinary failure is bare fail; assertion still expects an automatic diagnostic.

```text
Failure/Error: ?assertMatch({ fail , _ }, quod_prolog : prove_ro ( Ns , { space_placement , room , Subject , { '_' } } ))
```

## 7) quod_physics_tests:-live_source_missing_space_admission_test_/0-fun-9-/0

Log line 32586. Signed ordinary failure; update its assertion or unwrap bare failure in the existing read helper.

```text
Failure/Error: ?assertMatch({ ok , _ , { normalized , { failed , _ } } }, door_action ( Source , Placement ))
```

## 8) quod_physics_tests:-live_source_withdrawal_after_reclassification_test_/0-fun-12-/0: space

Log line 32753. Ordinary failure is bare fail; assertion still expects an automatic diagnostic.

```text
Failure/Error: ?assertMatch({ fail , _ }, quod_prolog : prove_ro ( Ns , { space_placement , room , Subject , { '_' } } ))
```

## 9) quod_physics_tests:-live_source_withdrawal_after_reclassification_test_/0-fun-12-/0: untyped

Log line 32762. Ordinary failure is bare fail; assertion still expects an automatic diagnostic.

```text
Failure/Error: ?assertMatch({ fail , _ }, quod_prolog : prove_ro ( Ns , { space_placement , room , Subject , { '_' } } ))
```

## 10) quod_physics_tests:-numeric_geometry_and_hinge_refusals_test_/0-fun-27-/0

Log line 32771. Ordinary failure is bare fail; assertion still expects an automatic diagnostic.

```text
Failure/Error: ?assertMatch({ fail , _ }, quod_prolog : prove_ro ( Ns , { physics_positive_scalar , Max + 1 } ))
```

## 11) quod_physics_tests:-hot_control_policy_reasons_test_/0-fun-10-/0

Log line 32780. Ordinary failure is bare fail; assertion still expects an automatic diagnostic.

```text
Failure/Error: ?assertMatch({ fail , _ }, quod_prolog : prove_ro ( Ns , Fact ))
```

## 12) quod_physics_tests:-signed_control_releases_only_successful_proof_test_/0-fun-25-/0

Log line 32789. Signed ordinary failure; update its assertion or unwrap bare failure in the existing read helper.

```text
Failure/Error: ?assertMatch({ ok , _ , { normalized , { failed , _ } } }, control_goal ( { '::' , Ns , { physics_test_cut , Go } } ))
```

## 13) quod_physics_tests:-explicit_activation_cancellation_test_/0-fun-1-/0: never_submitted

Log line 33008. Signed ordinary failure; update its assertion or unwrap bare failure in the existing read helper.

```text
Failure/Error: ?assertMatch({ ok , _ , { normalized , { failed , _ } } }, submit_fixture ( F , Goal ))
```

## 14) quod_physics_tests:-explicit_activation_cancellation_test_/0-fun-1-/0: prepared_before_cancellation

Log line 33381. Signed ordinary failure; update its assertion or unwrap bare failure in the existing read helper.

```text
Failure/Error: ?assertMatch({ ok , _ , { normalized , { failed , _ } } }, submit_fixture ( F , Goal ))
```

## 15) quod_physics_tests:-explicit_activation_cancellation_test_/0-fun-1-/0: activation_wins

Log line 33752. Signed ordinary failure; update its assertion or unwrap bare failure in the existing read helper.

```text
Failure/Error: ?assertMatch({ ok , _ , { normalized , { failed , _ } } }, submit_fixture ( F , Goal ))
```

## 16) quod_physics_tests:-explicit_activation_cancellation_test_/0-fun-1-/0: disabled

Log line 34121. Signed ordinary failure; update its assertion or unwrap bare failure in the existing read helper.

```text
Failure/Error: ?assertMatch({ ok , _ , { normalized , { failed , _ } } }, submit_fixture ( F , Goal ))
```

## 17) quod_physics_tests:-pending_custody_and_delayed_sample_cannot_finish_new_close_test_/0-fun-16-/0

Log line 34492. Signed ordinary failure; update its assertion or unwrap bare failure in the existing read helper.

```text
Failure/Error: ?assertMatch({ ok , _ , { normalized , { failed , _ } } }, quod_client_goal_ingress : submit ( Bytes , Sig ))
```

## 18) quod_physics_tests:-signed_chair_push_checkpoint_and_recovery_test_/0-fun-36-/0

Log line 34815. Signed ordinary failure; update its assertion or unwrap bare failure in the existing read helper.

```text
Failure/Error: ?assertMatch({ ok , _ , { normalized , { failed , _ } } }, OldCommand ( 0 , { push , { body , 3 , 1 } , { vector , 5001 , 0 , 0 } } ))
```

## 19) quod_physics_tests:-hinged_receiver_completion_is_atomic_test_/0-fun-1-/0: commit

Log line 35028. Ordinary failure is bare fail; assertion still expects an automatic diagnostic.

```text
Failure/Error: ?assertMatch({ fail , _ }, quod_prolog : prove_ro ( Receiver , { received_hinged , R } ))
```

## 20) quod_physics_tests:-hinged_receiver_completion_is_atomic_test_/0-fun-1-/0: denied

Log line 35037. Ordinary failure is bare fail; assertion still expects an automatic diagnostic.

```text
Failure/Error: ?assertMatch({ fail , _ }, quod_prolog : prove_ro ( Receiver , { received_hinged , R } ))
```

## 21) quod_physics_tests:-hinged_receiver_completion_is_atomic_test_/0-fun-1-/0: rollback

Log line 35046. Ordinary failure is bare fail; assertion still expects an automatic diagnostic.

```text
Failure/Error: ?assertMatch({ fail , _ }, quod_prolog : prove_ro ( Receiver , { received_hinged , R } ))
```

## 22) quod_physics_tests:-hinged_receiver_completion_is_atomic_test_/0-fun-1-/0: conflict

Log line 35055. Ordinary failure is bare fail; assertion still expects an automatic diagnostic.

```text
Failure/Error: ?assertMatch({ fail , _ }, quod_prolog : prove_ro ( Receiver , { received_hinged , R } ))
```

## 23) quod_physics_tests:-authored_hinged_obstruction_and_permissions_test_/0-fun-9-/0

Log line 35064. Ordinary failure is bare fail; assertion still expects an automatic diagnostic.

```text
Failure/Error: ?assertMatch({ fail , _ }, quod_prolog : prove_ro ( Ns , { hinged_result , { '_' } , { '_' } } ))
```

## 24) quod_agent_custody_tests:-recovery_acl_external_query_is_rejected_test_/0-fun-1-/0

Log line 35073. Earlier expectation edit incorrectly discarded an explicit refusal; restore the reasoned check.

```text
Failure/Error: ?assertMatch({ ok , _ , { normalized , fail } }, Result)
```

## 25) quod_agent_custody_tests:-worker_refuses_custody_for_wrong_target_anchor_test_/0-fun-4-/0

Log line 35325. Ordinary failure is bare fail; assertion still expects an automatic diagnostic.

```text
Failure/Error: ?assertMatch({ fail , _ }, quod_prolog : prove_ro ( Ns , { agent_hosted , actor , Node , 2 , { '_' } } ))
```

## 26) quod_agent_hosting_tests:-class_owner_hosting_transitions_test_/0-fun-19-/0

Log line 35334. Signed ordinary failure; update its assertion or unwrap bare failure in the existing read helper.

```text
Failure/Error: ?assertMatch({ ok , _ , { normalized , { failed , _ } } }, signed_owner_transition ( Owner , Denied ))
```

## 27) quod_agent_hosting_tests:-class_owner_signing_preserves_storage_and_policy_boundaries_test_/0-fun-15-/0

Log line 35534. Ordinary failure is bare fail; assertion still expects an automatic diagnostic.

```text
Failure/Error: ?assertMatch({ failed , _ }, signed_read ( Ns , Read ))
```

## 28) quod_agent_hosting_tests:-hosted_reactions_and_incarnation_recovery_test_/0-fun-0-/0

Log line 35543. Ordinary failure is bare fail; assertion still expects an automatic diagnostic.

```text
Failure/Error: ?assertMatch({ fail , _ }, quod_prolog : execute ( Ns , agent ( { goal , { agent_assignment , Ref , Node , 2 , Node , 3 , Key } } ) ))
```

## 29) quod_agent_hosting_tests:-fipa_action_and_reply_commit_together_test_/0-fun-0-/0

Log line 35552. Ordinary failure is bare fail; assertion still expects an automatic diagnostic.

```text
Failure/Error: ?assertMatch({ fail , _ }, quod_prolog : prove_ro ( SenderNs , { fipa_conversation , actor , Id , { '_' } , { '_' } , { '_' } , { '_' } } ))
```

## 30) quod_agent_hosting_tests:-node_execution_policy_installs_through_ordinary_signed_goal_test_/0-fun-6-/0

Log line 35561. Ordinary failure is bare fail; assertion still expects an automatic diagnostic.

```text
Failure/Error: ?assertMatch({ fail , _ }, quod_prolog : prove_ro ( Ns , { ping , delegated } ))
```

## 31) quod_agent_hosting_tests:-node_executor_requires_exact_delegation_at_execution_test_/0-fun-0-/0

Log line 35570. Ordinary failure is bare fail; assertion still expects an automatic diagnostic.

```text
Failure/Error: ?assertMatch({ fail , _ }, quod_prolog : prove_ro ( Ns , { ping , delegated } ))
```

## 32) quod_agent_hosting_tests:-atomic_recovery_commits_one_diff_and_restores_projection_test_/0-fun-1-/0

Log line 35579. Ordinary failure is bare fail; assertion still expects an automatic diagnostic.

```text
Failure/Error: ?assertMatch({ fail , _ }, Report)
```

## 33) quod_agent_hosting_tests:-failed_atomic_recovery_does_not_commit_its_report_test_/0-fun-1-/0

Log line 35588. Ordinary failure is bare fail; assertion still expects an automatic diagnostic.

```text
Failure/Error: ?assertMatch({ fail , _ }, Report)
```

## 34) quod_agent_reaction_tests:-ordinary_owned_reactions_use_signed_goal_admission_test_/0-fun-12-/0

Log line 35597. Ordinary failure is bare fail; assertion still expects an automatic diagnostic.

```text
Failure/Error: ?assertMatch({ fail , _ }, quod_prolog : prove_ro ( Ns , forbidden_goal_write ))
```

## 35) quod_class_permissions_tests:signed_foreign_guard/0

Log line 35606. Signed ordinary failure; update its assertion or unwrap bare failure in the existing read helper.

```text
Failure/Error: ?assertMatch(fail, quod_lobby_tests : read ( Ctx , Ask ( Store , { operation_authorized , { instance , inherited } , { review , N } } ) ))
```

## 36) quod_class_permissions_tests:signed_boundaries/0

Log line 35735. Signed ordinary failure; update its assertion or unwrap bare failure in the existing read helper.

```text
Failure/Error: ?assertMatch({ fail , _ }, quod_lobby_tests : read ( Ctx , Scope ( { instance_permission , report1 , edit , { '_' } } ) ))
```

## 37) quod_constructor_tests:signed_qualified_class/0

Log line 35860. Signed ordinary failure; update its assertion or unwrap bare failure in the existing read helper.

```text
Failure/Error: ?assertMatch(fail, quod_lobby_tests : read ( Ctx , Ask ( Owner , { attribute , { '_' } , flag , good } ) ))
```

## 38) quod_constructor_tests:signed_owner/0

Log line 35981. Signed ordinary failure; update its assertion or unwrap bare failure in the existing read helper.

```text
Failure/Error: ?assertMatch(fail, quod_lobby_tests : read ( Ctx , Scope ( { attribute , refused , { '_' } , { '_' } } ) ))
```

## 39) quod_e2e_tests:-t_failing_proofs_no_ets_leak/1-fun-4-/0

Log line 36101. Ordinary failure is bare fail; assertion still expects an automatic diagnostic.

```text
Failure/Error: ?assertMatch({ fail , [ _ | _ ] }, quod_prolog : prove ( Ns , { undefined_pred , k } ))
```

## 40) quod_gui_components_tests:-remaining_controls_preserve_binding_and_atomic_refusal_test_/0-fun-12-/0

Log line 36108. Signed ordinary failure; update its assertion or unwrap bare failure in the existing read helper.

```text
Failure/Error: ?assertMatch(fail, read ( Ctx , Ns , { gui_schema , extra , { 0 } , { 1 } } ))
```

## 41) quod_gui_components_tests:-composition_uses_inherited_defaults_and_only_binds_inputs_test_/0-fun-19-/0

Log line 36252. Signed ordinary failure; update its assertion or unwrap bare failure in the existing read helper.

```text
Failure/Error: ?assertMatch(fail, read ( Ctx , Ns , Bind ( Values ++ [ { field , loading , 65 } ] ) ))
```

## 42) quod_gui_components_tests:-input_variants_keep_typed_binding_and_rollback_test_/0-fun-17-/0

Log line 36430. Signed ordinary failure; update its assertion or unwrap bare failure in the existing read helper.

```text
Failure/Error: ?assertMatch({ fail , _ }, read ( Ctx , Ns , invalid_variant_write ))
```

## 43) quod_gui_components_tests:-elaborate_form_uses_one_vocabulary_projection_test_/0-fun-12-/0

Log line 36564. Signed ordinary failure; update its assertion or unwrap bare failure in the existing read helper.

```text
Failure/Error: ?assertMatch(fail, read ( Ctx , Ns , { gui_bind , elaborate , Revision , apply , Values ++ [ hd ( Values ) ] , { 0 } } ))
```

## 44) quod_gui_components_tests:-forms_use_the_same_signed_ontology_path_test_/0-fun-2-/0

Log line 36989. Signed ordinary failure; update its assertion or unwrap bare failure in the existing read helper.

```text
Failure/Error: ?assertMatch({ fail , _ }, read ( Ctx , Ns , invalid_form_write ))
```

## 45) quod_gui_examples_tests:examples/0

Log line 37124. Signed ordinary failure; update its assertion or unwrap bare failure in the existing read helper.

```text
Failure/Error: ?assertMatch({ fail , _ }, read ( Ctx , ResponderNs , { gui_question , Q , { '_' } , { '_' } , { '_' } , { '_' } , { '_' } } ))
```

## 46) quod_gui_examples_tests:world_library/0

Log line 37293. Signed ordinary failure; update its assertion or unwrap bare failure in the existing read helper.

```text
Failure/Error: ?assertMatch({ ok , _ , { normalized , { failed , _ } } }, quod_lobby_tests : submit ( Ctx , execute , scope ( Ns , gui ( { gui_submit , question_ref ( Ns , Q ) , Revision , create_world , Fields } ) ) ))
```

## 47) quod_gui_hud_tests:-hud_composes_standing_context_and_contributions_test_/0-fun-30-/0

Log line 37601. Signed ordinary failure; update its assertion or unwrap bare failure in the existing read helper.

```text
Failure/Error: ?assertMatch({ ok , _ , { normalized , { failed , _ } } }, quod_client_goal_ingress : submit ( Bytes2 , Sig2 ))
```

## 48) quod_gui_menu_tests:-overflow_nests_under_more_and_keeps_pins_test_/0-fun-22-/0

Log line 37795. Earlier expectation edit incorrectly discarded an explicit refusal; restore the reasoned check.

```text
Failure/Error: ?assertMatch(fail, quod_prolog : prove_ro ( Gui , { menu_tree , Bad , { 'T' } } ))
```

## 49) quod_gui_operations_tests:-prebound_creation_output_is_refused_test_/0-fun-1-/0

Log line 37804. Negative-test helper assumes every logical failure has encoded reasons.

```text
Failure/Error: {error,badarg,
```

## 50) quod_gui_operations_tests:-execution_preserves_authored_output_aliases_test_/0-fun-5-/0

Log line 37842. Negative-test helper assumes every logical failure has encoded reasons.

```text
Failure/Error: {error,badarg,
```

## 51) quod_gui_operations_tests:-offered_creation_and_instance_operation_test_/0-fun-14-/0

Log line 37880. Negative-test helper assumes every logical failure has encoded reasons.

```text
Failure/Error: {error,badarg,
```

## 52) quod_gui_operations_tests:-binding_refuses_invalid_or_changed_contract_test_/0-fun-5-/0

Log line 37918. Negative-test helper assumes every logical failure has encoded reasons.

```text
Failure/Error: {error,badarg,
```

## 53) quod_gui_question_tests:-native_scope_is_read_only_and_keeps_original_request_test_/0-fun-10-/0

Log line 37960. Signed ordinary failure; update its assertion or unwrap bare failure in the existing read helper.

```text
Failure/Error: ?assertMatch(fail, read ( Ctx , Ns , { saved , ok } ))
```

## 54) quod_gui_question_tests:-native_presentation_uses_original_scope_and_closed_effect_codec_test_/0-fun-23-/0

Log line 38087. Signed ordinary failure; update its assertion or unwrap bare failure in the existing read helper.

```text
Failure/Error: ?assertMatch(fail, read ( Ctx , HumanNs , { saved , ok } ))
```

## 55) quod_gui_question_tests:-live_opening_commits_question_hud_and_presentation_together_test_/0-fun-38-/0

Log line 38218. Earlier expectation edit incorrectly discarded an explicit refusal; restore the reasoned check.

```text
Failure/Error: ?assertMatch({ ok , _ , { normalized , fail } }, quod_lobby_tests : submit ( Ctx , execute , Goal ))
```

## 56) quod_gui_question_tests:-accepted_question_transitions_use_signed_atomic_owners_test_/0-fun-60-/0

Log line 38354. Earlier expectation edit incorrectly discarded an explicit refusal; restore the reasoned check.

```text
Failure/Error: ?assertMatch({ ok , _ , { normalized , fail } }, quod_lobby_tests : submit ( Ctx , execute , Goal ))
```

## 57) quod_gui_question_tests:-committed_answer_automatically_completes_test_/0-fun-24-/0

Log line 38534. Ordinary failure is bare fail; assertion still expects an automatic diagnostic.

```text
Failure/Error: ?assertMatch({ fail , _ }, quod_prolog : prove_ro ( Ns , Row ))
```

## 58) quod_gui_stage1_tests:-non_space_binding_and_updates_test_/0-fun-5-/0

Log line 38543. Signed ordinary failure; update its assertion or unwrap bare failure in the existing read helper.

```text
Failure/Error: ?assertMatch({ ok , _ , { normalized , { failed , _ } } }, Stale)
```

## 59) quod_lifecycle_single_path_tests:-m1a_signup_terms_test_/0-fun-7-/0

Log line 38776. Negative-test helper assumes every logical failure has encoded reasons.

```text
Failure/Error: {error,
```

## 60) quod_lifecycle_single_path_tests:-m1a_seven_foundations_test_/0-fun-6-/0

Log line 38925. Signed ordinary failure; update its assertion or unwrap bare failure in the existing read helper.

```text
Failure/Error: ?assertMatch({ ok , _ , { normalized , { read , _ , { failed , _ } } } }, submit_lobby ( Second , read , { '::' , ? ROOT_NS , { system_source_access , { ontology_ref , << "quod:user" >> , UserClass } , { 0 } } } ))
```

## 61) quod_lobby_tests:-class_owner_space_creation_preserves_world_test_/0-fun-10-/0

Log line 39080. Signed ordinary failure; update its assertion or unwrap bare failure in the existing read helper.

```text
Failure/Error: ?assertMatch({ ok , _ , { normalized , { failed , _ } } }, submit ( Ctx , execute , Edit ))
```

## 62) quod_lobby_tests:-lobby_projection_recovery_test_/0-fun-19-/0

Log line 39264. Signed ordinary failure; update its assertion or unwrap bare failure in the existing read helper.

```text
Failure/Error: ?assertMatch({ fail , _ }, read ( Ctx , { '::' , Ns , { ',' , { current_ontology_identity , Ns , << 0 : 256 >> } , space_view ( Ns , personal_lobby , playing , { 0 } ) } } ))
```

## 63) quod_lobby_tests:-modelling_and_material_libraries_test_/0-fun-38-/0

Log line 39428. Signed ordinary failure; update its assertion or unwrap bare failure in the existing read helper.

```text
Failure/Error: ?assertMatch({ fail , _ }, Ask ( ModelNs , { model , [ { 0 } ] , { 1 } } ))
```

## 64) quod_lobby_tests:-signed_prolog_eidolon_edits_use_target_policy_test_/0-fun-16-/0

Log line 39562. Signed ordinary failure; update its assertion or unwrap bare failure in the existing read helper.

```text
Failure/Error: ?assertMatch({ fail , _ }, read ( Ctx , Scope ( Ns , { editor_fact , saved } ) ))
```

## 65) quod_lobby_tests:-ontology_instances_share_selection_and_authorized_inspection_test_/0-fun-28-/0

Log line 39700. Signed ordinary failure; update its assertion or unwrap bare failure in the existing read helper.

```text
Failure/Error: ?assertMatch({ fail , _ }, read ( Ctx , { '::' , Ns , { ',' , { current_ontology_identity , Ns , << 0 : 256 >> } , { entity_eidolons , Target , { 0 } } } } ))
```

## 66) quod_lobby_tests:-presentation_modes_and_ground_lens_targets_use_authorized_owner_reads_test_/0-fun-8-/0

Log line 39856. Signed ordinary failure; update its assertion or unwrap bare failure in the existing read helper.

```text
Failure/Error: ?assertMatch({ fail , _ }, read ( Ctx , Workspace ))
```

## 67) quod_lobby_tests:-public_system_ontology_source_is_readable_but_not_mutable_test_/0-fun-30-/0

Log line 40045. Signed ordinary failure; update its assertion or unwrap bare failure in the existing read helper.

```text
Failure/Error: ?assertMatch({ fail , _ }, read ( Ctx , editor_scope ( Tools , { prolog_source , { ontology_ref , << "quod:gui" >> , << 0 : 256 >> } , { '/' , model , 2 } , { 0 } } ) ))
```

## 68) quod_lobby_tests:-system_ontology_editing_uses_universal_scope_identity_test_/0-fun-10-/0

Log line 40204. Signed ordinary failure; update its assertion or unwrap bare failure in the existing read helper.

```text
Failure/Error: ?assertMatch({ fail , _ }, read ( Ctx , { '::' , Ns , { current_ontology_identity , Ns , << 0 : 256 >> } } ))
```

## 69) quod_lobby_tests:-local_inspection_cannot_fall_back_after_root_source_denial_test_/0-fun-5-/0

Log line 40336. Signed ordinary failure; update its assertion or unwrap bare failure in the existing read helper.

```text
Failure/Error: ?assertMatch({ fail , _ }, read ( Ctx , editor_scope ( Root , { system_source_access , Target , { 0 } } ) ))
```

## 70) quod_lobby_tests:-scoped_routes_reuse_the_directory_and_preserve_private_admission_test_/0-fun-18-/0

Log line 40489. Signed ordinary failure; update its assertion or unwrap bare failure in the existing read helper.

```text
Failure/Error: ?assertMatch({ fail , _ }, read ( Ctx , editor_scope ( Ns , forbidden_route_write ) ))
```

## 71) quod_node_context_tests:-permitted_recovery_helper_cannot_borrow_node_privileges_test_/0-fun-10-/0

Log line 40625. Ordinary failure is bare fail; assertion still expects an automatic diagnostic.

```text
Failure/Error: ?assertMatch({ fail , _ }, quod_prolog : prove_ro ( NodeNs , borrowed_node_authority ))
```

## 72) quod_outcome_result_tests:-lost_reply_recovers_selected_bindings_test_/0-fun-1-/0: ordinary

Log line 40634. Ordinary failure is bare fail; assertion still expects an automatic diagnostic.

```text
Failure/Error: ?assertMatch({ fail , _ }, quod_prolog : prove_ro ( Writer , { created , Reference } ))
```

## 73) quod_outcome_result_tests:-lost_reply_recovers_selected_bindings_test_/0-fun-1-/0: foreign

Log line 40643. Ordinary failure is bare fail; assertion still expects an automatic diagnostic.

```text
Failure/Error: ?assertMatch({ fail , _ }, quod_prolog : prove_ro ( Writer , { created , Reference } ))
```

## 74) quod_outcome_result_tests:-lost_reply_recovers_selected_bindings_test_/0-fun-1-/0: atomic

Log line 40652. Ordinary failure is bare fail; assertion still expects an automatic diagnostic.

```text
Failure/Error: ?assertMatch({ fail , _ }, quod_prolog : prove_ro ( Writer , { created , Reference } ))
```

## 75) quod_personal_agent_tests:-signup_terms_only_test_/0-fun-9-/0

Log line 40661. Signed ordinary failure; update its assertion or unwrap bare failure in the existing read helper.

```text
Failure/Error: ?assertMatch({ ok , _ , { normalized , { read , _ , { failed , _ } } } }, Check ( O ))
```

## 76) quod_personal_agent_tests:-immediate_instruction_uses_distinct_actor_test_/0-fun-0-/0

Log line 44298. Signed ordinary failure; update its assertion or unwrap bare failure in the existing read helper.

```text
Failure/Error: ?assertMatch({ ok , _ , { normalized , { failed , _ } } }, submit ( request ( Ctx , execute , Goal ) ))
```

## 77) quod_personal_agent_tests:-foreign_and_atomic_instruction_results_test_/0-fun-2-/0: foreign

Log line 44455. Ordinary failure is bare fail; assertion still expects an automatic diagnostic.

```text
Failure/Error: ?assertMatch({ fail , _ }, quod_prolog : prove_ro ( Target , { can_invoke , element ( 3 , Work ) , Agent , [ Ns ] , Target } ))
```

## 78) quod_personal_agent_tests:-foreign_and_atomic_instruction_results_test_/0-fun-2-/0: atomic

Log line 44464. Ordinary failure is bare fail; assertion still expects an automatic diagnostic.

```text
Failure/Error: ?assertMatch({ fail , _ }, quod_prolog : prove_ro ( Target , { can_invoke , element ( 3 , Work ) , Agent , [ Ns ] , Target } ))
```

## 79) quod_personal_agent_tests:-interrupted_instruction_never_dispatches_test_/0-fun-2-/0: cancel

Log line 44473. Ordinary failure is bare fail; assertion still expects an automatic diagnostic.

```text
Failure/Error: ?assertMatch({ fail , _ }, quod_prolog : prove_ro ( Ns , forbidden_later ))
```

## 80) quod_personal_agent_tests:-interrupted_instruction_never_dispatches_test_/0-fun-2-/0: deadline

Log line 44482. Ordinary failure is bare fail; assertion still expects an automatic diagnostic.

```text
Failure/Error: ?assertMatch({ fail , _ }, quod_prolog : prove_ro ( Ns , forbidden_later ))
```

## 81) quod_personal_agent_tests:-interrupted_instruction_never_dispatches_test_/0-fun-2-/0: host_restart

Log line 44491. Ordinary failure is bare fail; assertion still expects an automatic diagnostic.

```text
Failure/Error: ?assertMatch({ fail , _ }, quod_prolog : prove_ro ( Ns , forbidden_later ))
```

## 82) quod_personal_agent_tests:-cancellation_during_target_proof_preserves_the_original_identity_test_/0-fun-6-/0

Log line 44500. Ordinary failure is bare fail; assertion still expects an automatic diagnostic.

```text
Failure/Error: ?assertMatch({ fail , _ }, quod_prolog : prove_ro ( Ns , forbidden_later ))
```

## 83) quod_personal_agent_tests:-retained_but_unsubmitted_instruction_is_not_replayed_test_/0-fun-7-/0

Log line 44509. Ordinary failure is bare fail; assertion still expects an automatic diagnostic.

```text
Failure/Error: ?assertMatch({ fail , _ }, quod_prolog : prove_ro ( Ns , forbidden_later ))
```

## 84) quod_personal_agent_tests:-unavailable_actor_does_not_dispatch_on_restart_test_/0-fun-5-/0

Log line 44518. Ordinary failure is bare fail; assertion still expects an automatic diagnostic.

```text
Failure/Error: ?assertMatch({ fail , _ }, quod_prolog : prove_ro ( Ns , forbidden_later ))
```

## 85) quod_personal_agent_tests:-unauthorized_and_staged_signing_are_denied_test_/0-fun-6-/0

Log line 44527. Ordinary failure is bare fail; assertion still expects an automatic diagnostic.

```text
Failure/Error: ?assertMatch({ fail , _ }, quod_prolog : prove_ro ( Ns , forbidden ))
```

## 86) quod_personal_agent_tests:-revocation_preserves_authorized_result_recovery_test_/0-fun-8-/0

Log line 44536. Ordinary failure is bare fail; assertion still expects an automatic diagnostic.

```text
Failure/Error: ?assertMatch({ fail , _ }, quod_prolog : prove_ro ( Ns , forbidden ))
```

## 87) quod_personal_agent_tests:-human_revocation_between_signing_and_custody_refuses_dispatch_test_/0-fun-4-/0

Log line 44545. Ordinary failure is bare fail; assertion still expects an automatic diagnostic.

```text
Failure/Error: ?assertMatch({ fail , _ }, quod_prolog : prove_ro ( Ns , forbidden ))
```

## 88) quod_personal_agent_tests:-endpoint_refusal_preserves_prior_operations_test_/0-fun-11-/0: fresh

Log line 44554. Ordinary failure is bare fail; assertion still expects an automatic diagnostic.

```text
Failure/Error: ?assertMatch({ fail , _ }, quod_prolog : prove_ro ( Ns , original_work ))
```

## 89) quod_personal_agent_tests:-authorization_does_not_reparse_retained_history_test_/0-fun-10-/0

Log line 44563. Ordinary failure is bare fail; assertion still expects an automatic diagnostic.

```text
Failure/Error: ?assertMatch({ fail , _ }, quod_prolog : prove_ro ( Ns , { can_invoke , Work , Agent , [ Ns ] , Ns } ))
```

## 90) quod_physics_control_tests:-signed_binding_switch_and_release_test_/0-fun-12-/0

Log line 44572. Signed ordinary failure; update its assertion or unwrap bare failure in the existing read helper.

```text
Failure/Error: ?assertMatch({ normalized , { read , _ , { failed , _ } } }, read ( F ))
```

## 91) quod_physics_control_tests:-binding_permission_and_geometry_guards_test_/0-fun-8-/0

Log line 44587. Logical result shape requires the owning signed-result/helper correction; retain state checks.

```text
Failure/Error: ?assertMatch({ normalized , { failed , _ } }, action ( F , bind ( 0 , none , unknown , eye ) ))
```

## 92) quod_predicate_removal_tests:-signed_definition_removal_test_/0-fun-5-/0

Log line 44596. Signed ordinary failure; update its assertion or unwrap bare failure in the existing read helper.

```text
Failure/Error: ?assertMatch({ ok , _ , { normalized , { failed , _ } } }, quod_client_goal_ingress : submit ( Bytes , Sig ))
```

## 93) quod_predicate_removal_tests:-signed_origin_removal_recovery_test_/0-fun-2-/0

Log line 44707. Signed ordinary failure; update its assertion or unwrap bare failure in the existing read helper.

```text
Failure/Error: ?assertMatch({ ok , _ , { normalized , { read , _ , { failed , _ } } } }, quod_client_goal_ingress : submit ( Bytes , Sig ))
```

## 94) quod_predicate_removal_tests:-signed_denial_atomic_rollback_and_conflict_test_/0-fun-2-/0

Log line 44825. Signed ordinary failure; update its assertion or unwrap bare failure in the existing read helper.

```text
Failure/Error: ?assertMatch({ ok , _ , { normalized , { failed , _ } } }, quod_client_goal_ingress : submit ( Bytes , Sig ))
```

## 95) quod_predicate_withdrawal_tests:-signed_contents_and_selected_editor_withdraw_test_/0-fun-24-/0: module 'quod_predicate_withdrawal_tests'

Log line 44946. Signed ordinary failure; update its assertion or unwrap bare failure in the existing read helper.

```text
Failure/Error: ?assertMatch({ fail , _ }, quod_lobby_tests : read ( Ctx , scope ( Ns , Anchor , { client_eidolon , Subject , Choice , { 0 } } ) ))
```

## 96) quod_reaction_authority_tests:-editable_lobby_notification_cannot_borrow_node_authority_test_/0-fun-8-/0

Log line 45128. Ordinary failure is bare fail; assertion still expects an automatic diagnostic.

```text
Failure/Error: ?assertMatch({ fail , _ }, quod_prolog : prove_ro ( Root , authority_root_marker ))
```

## 97) quod_resource_lifecycle_tests:-committed_height_wakes_context_dependent_selection_test_/0-fun-7-/0

Log line 45135. Ordinary failure is bare fail; assertion still expects an automatic diagnostic.

```text
Failure/Error: ?assertMatch({ fail , _ }, quod_prolog : prove_ro ( Ns , must_not_apply ))
```

## 98) quod_resource_lifecycle_tests:-committed_height_does_not_wake_predicate_only_selection_test_/0-fun-2-/0

Log line 45144. Ordinary failure is bare fail; assertion still expects an automatic diagnostic.

```text
Failure/Error: ?assertMatch({ fail , _ }, quod_prolog : prove_ro ( Ns , must_not_apply ))
```

## 99) quod_resource_lifecycle_tests:-queued_height_advance_supersedes_selection_before_installation_test_/0-fun-7-/0

Log line 45153. Ordinary failure is bare fail; assertion still expects an automatic diagnostic.

```text
Failure/Error: ?assertMatch({ fail , _ }, quod_prolog : prove_ro ( Ns , must_not_apply ))
```

## 100) quod_root_resource_lifecycle_tests:-invalid_committed_limits_withdraw_and_resume_from_dependency_notices_test_/0-fun-13-/0

Log line 45162. Ordinary failure is bare fail; assertion still expects an automatic diagnostic.

```text
Failure/Error: ?assertMatch({ fail , _ }, quod_prolog : execute ( ? ROOT , { ',' , { set_effect_custody_limits , 1 , 0 } , fail } ))
```

## 101) quod_source_view_tests:-committed_signed_read_preserves_bindings_and_scope_restrictions_test_/0-fun-13-/0

Log line 45171. Signed ordinary failure; update its assertion or unwrap bare failure in the existing read helper.

```text
Failure/Error: ?assertMatch({ fail , _ }, quod_lobby_tests : read ( Ctx , { '::' , Owner , leaked } ))
```

## 102) quod_source_view_tests:class_owned_scene/0

Log line 45285. Signed ordinary failure; update its assertion or unwrap bare failure in the existing read helper.

```text
Failure/Error: ?assertMatch({ fail , _ }, HiddenRead)
```

## 103) quod_space_creation_tests:-signed_empty_space_results_and_recovery_test_/0-fun-10-/0: ordinary

Log line 45447. Ordinary failure is bare fail; assertion still expects an automatic diagnostic.

```text
Failure/Error: ?assertMatch({ fail , _ }, quod_prolog : prove_ro ( Ns , Goal ))
```

## 104) quod_space_creation_tests:-signed_empty_space_results_and_recovery_test_/0-fun-10-/0: foreign

Log line 45456. Ordinary failure is bare fail; assertion still expects an automatic diagnostic.

```text
Failure/Error: ?assertMatch({ fail , _ }, quod_prolog : prove_ro ( Ns , Goal ))
```

## 105) quod_space_creation_tests:-signed_empty_space_results_and_recovery_test_/0-fun-10-/0: atomic

Log line 45465. Ordinary failure is bare fail; assertion still expects an automatic diagnostic.

```text
Failure/Error: ?assertMatch({ fail , _ }, quod_prolog : prove_ro ( Ns , Goal ))
```

## 106) quod_space_creation_tests:-explicit_and_near_agent_placement_test_/0-fun-3-/0

Log line 45474. Ordinary failure is bare fail; assertion still expects an automatic diagnostic.

```text
Failure/Error: ?assertMatch({ fail , _ }, quod_prolog : prove_ro ( Ns , Goal ))
```

## 107) quod_space_creation_tests:-viewer_pose_placement_test_/0-fun-3-/0

Log line 45483. Signed ordinary failure; update its assertion or unwrap bare failure in the existing read helper.

```text
Failure/Error: ?assertMatch({ ok , _ , { normalized , { failed , _ } } }, R)
```

## 108) quod_space_creation_tests:-explicit_owner_and_class_defaults_test_/0-fun-1-/0

Log line 45669. Signed ordinary failure; update its assertion or unwrap bare failure in the existing read helper.

```text
Failure/Error: ?assertMatch({ ok , _ , { normalized , { failed , _ } } }, R)
```

## 109) quod_space_creation_tests:-authorization_and_lookup_failures_never_fall_back_test_/0-fun-7-/0

Log line 45825. Signed ordinary failure; update its assertion or unwrap bare failure in the existing read helper.

```text
Failure/Error: ?assertMatch({ ok , _ , { normalized , { failed , _ } } }, R)
```

## 110) quod_space_creation_tests:-existing_occupants_and_creation_commit_together_test_/0-fun-10-/0: local

Log line 46028. Signed ordinary failure; update its assertion or unwrap bare failure in the existing read helper.

```text
Failure/Error: ?assertMatch({ ok , _ , { normalized , { failed , _ } } }, R)
```

## 111) quod_space_creation_tests:-existing_occupants_and_creation_commit_together_test_/0-fun-10-/0: foreign

Log line 46268. Signed ordinary failure; update its assertion or unwrap bare failure in the existing read helper.

```text
Failure/Error: ?assertMatch({ ok , _ , { normalized , { failed , _ } } }, R)
```

## 112) quod_space_creation_tests:-atomic_completion_wait_includes_complete_record_test_/0-fun-6-/0

Log line 46507. Signed ordinary failure; update its assertion or unwrap bare failure in the existing read helper.

```text
Failure/Error: ?assertMatch({ ok , _ , { normalized , { failed , _ } } }, R)
```

## 113) quod_space_tests:-class_owner_creation_and_action_chain_test_/0-fun-5-/0

Log line 46711. Signed ordinary failure; update its assertion or unwrap bare failure in the existing read helper.

```text
Failure/Error: ?assertMatch({ ok , _ , { normalized , { read , _ , { failed , _ } } } }, read ( Ns , Goal ))
```

## 114) quod_space_tests:-ordinary_travel_atomic_test_/0-fun-2-/0

Log line 46828. Signed ordinary failure; update its assertion or unwrap bare failure in the existing read helper.

```text
Failure/Error: ?assertMatch({ ok , _ , { normalized , { failed , _ } } }, Result)
```

## 115) quod_space_tests:-space_semantics_and_recovery_test_/0-fun-5-/0

Log line 46993. Signed ordinary failure; update its assertion or unwrap bare failure in the existing read helper.

```text
Failure/Error: ?assertMatch({ ok , _ , { normalized , { read , _ , { failed , _ } } } }, read ( Ns , Goal ))
```

## 116) quod_space_tests:-competing_exclusive_admissions_test_/0-fun-12-/0: gallery

Log line 47111. Signed ordinary failure; update its assertion or unwrap bare failure in the existing read helper.

```text
Failure/Error: ?assertMatch({ ok , _ , { normalized , { read , _ , { failed , _ } } } }, read ( Ns , Goal ))
```

## 117) quod_space_tests:-competing_exclusive_admissions_test_/0-fun-12-/0: catalogue

Log line 47255. Signed ordinary failure; update its assertion or unwrap bare failure in the existing read helper.

```text
Failure/Error: ?assertMatch({ ok , _ , { normalized , { read , _ , { failed , _ } } } }, read ( Ns , Goal ))
```

## 118) quod_space_tests:-distinct_owner_authorization_test_/0-fun-3-/0: gallery

Log line 47399. Signed ordinary failure; update its assertion or unwrap bare failure in the existing read helper.

```text
Failure/Error: ?assertMatch({ ok , _ , { normalized , { failed , _ } } }, Result)
```

## 119) quod_space_tests:-distinct_owner_authorization_test_/0-fun-3-/0: catalogue

Log line 47579. Signed ordinary failure; update its assertion or unwrap bare failure in the existing read helper.

```text
Failure/Error: ?assertMatch({ ok , _ , { normalized , { failed , _ } } }, Result)
```

## 120) quod_space_tests:-ordinary_placement_rollback_and_recovery_test_/0-fun-4-/0

Log line 47761. Signed ordinary failure; update its assertion or unwrap bare failure in the existing read helper.

```text
Failure/Error: ?assertMatch({ ok , _ , { normalized , { read , _ , { failed , _ } } } }, read ( Ns , Goal ))
```

## 121) quod_space_tests:-ordinary_placement_committed_permissions_test_/0-fun-2-/0

Log line 47906. Signed ordinary failure; update its assertion or unwrap bare failure in the existing read helper.

```text
Failure/Error: ?assertMatch({ ok , _ , { normalized , { failed , _ } } }, Result)
```

## 122) quod_space_tests:-ordinary_placement_policy_conflicts_test_/0-fun-4-/0: source

Log line 48074. Signed ordinary failure; update its assertion or unwrap bare failure in the existing read helper.

```text
Failure/Error: ?assertMatch({ ok , _ , { normalized , { read , _ , { failed , _ } } } }, read ( Ns , Goal ))
```

## 123) quod_space_tests:-ordinary_placement_policy_conflicts_test_/0-fun-4-/0: destination

Log line 48216. Signed ordinary failure; update its assertion or unwrap bare failure in the existing read helper.

```text
Failure/Error: ?assertMatch({ ok , _ , { normalized , { read , _ , { failed , _ } } } }, read ( Ns , Goal ))
```

## 124) quod_space_tests:-same_ontology_ordinary_placement_test_/0-fun-1-/0

Log line 48359. Signed ordinary failure; update its assertion or unwrap bare failure in the existing read helper.

```text
Failure/Error: ?assertMatch({ ok , _ , { normalized , { read , _ , { failed , _ } } } }, read ( Ns , Goal ))
```

## 125) quod_space_tests:-ordinary_placement_and_shared_display_projection_test_/0-fun-13-/0

Log line 48503. Signed ordinary failure; update its assertion or unwrap bare failure in the existing read helper.

```text
Failure/Error: ?assertMatch({ ok , _ , { normalized , { read , _ , { failed , _ } } } }, read ( Ns , Goal ))
```

## 126) quod_space_tests:-physical_placement_requires_its_body_pose_test_/0-fun-1-/0

Log line 48622. Signed ordinary failure; update its assertion or unwrap bare failure in the existing read helper.

```text
Failure/Error: ?assertMatch({ ok , _ , { normalized , { read , _ , { failed , _ } } } }, read ( Ns , Goal ))
```

## Counts

- 52: Ordinary failure is bare fail; assertion still expects an automatic diagnostic.
- 64: Signed ordinary failure; update its assertion or unwrap bare failure in the existing read helper.
- 4: Earlier expectation edit incorrectly discarded an explicit refusal; restore the reasoned check.
- 5: Negative-test helper assumes every logical failure has encoded reasons.
- 1: Logical result shape requires the owning signed-result/helper correction; retain state checks.
