# Every failure in quod-eunit-01

The unchanged run reported 4,323 tests, 341 failures and one cancelled fixture.
Numbers below are the gate log's failure numbers. Cascades are retained as failures;
they are not counted as independent evidence of an engine semantic dependency.
The lifecycle setup failure at #169 left live owners and signing/network state.
The isolated follow-up passed all 77 checks in the seven affected network/history/receipt modules.

| Class | Count |
| --- | ---: |
| plain failure asserted as reasoned | 92 |
| automatic frames matched by fallback | 2 |
| normalized plain failure asserted as reasoned | 61 |
| explicit list differs | 2 |
| test helper calls element on plain failure | 5 |
| test helper handles only reasoned failure | 1 |
| effect journal treats absence as unavailable | 6 |
| setup: already_started | 139 |
| later fixture/network contamination; isolated checks passed | 27 |
| setup: identity_mismatch | 6 |

| Failure | Exact EUnit case | Class |
| --- | --- | --- |
| [1](quod-eunit-01.log:20392) | [quod_agent_vault_tests](/home/yan/src/quod/test/quod_agent_vault_tests.erl):`custody_and_signing_through_signed_ingress_and_foreign_scope_test/0` | plain failure asserted as reasoned |
| [2](quod-eunit-01.log:20399) | [quod_ask_tests](/home/yan/src/quod/test/quod_ask_tests.erl):`-ask_test_/0-fun-33-/0:315` | plain failure asserted as reasoned |
| [3](quod-eunit-01.log:20406) | [quod_ask_tests](/home/yan/src/quod/test/quod_ask_tests.erl):`-ask_test_/0-fun-26-/0:324` | plain failure asserted as reasoned |
| [4](quod-eunit-01.log:20413) | [quod_ask_tests](/home/yan/src/quod/test/quod_ask_tests.erl):`-ask_test_/0-fun-25-/0:325` | plain failure asserted as reasoned |
| [5](quod-eunit-01.log:20420) | [quod_ask_tests](/home/yan/src/quod/test/quod_ask_tests.erl):`-ask_test_/0-fun-24-/0:327` | plain failure asserted as reasoned |
| [6](quod-eunit-01.log:20427) | [quod_ask_tests](/home/yan/src/quod/test/quod_ask_tests.erl):`-ask_test_/0-fun-23-/0:328` | plain failure asserted as reasoned |
| [7](quod-eunit-01.log:20434) | [quod_ask_tests](/home/yan/src/quod/test/quod_ask_tests.erl):`-ask_test_/0-fun-22-/0:329` | plain failure asserted as reasoned |
| [8](quod-eunit-01.log:20441) | [quod_ask_tests](/home/yan/src/quod/test/quod_ask_tests.erl):`-ask_test_/0-fun-21-/0:330` | plain failure asserted as reasoned |
| [9](quod-eunit-01.log:20448) | [quod_ask_tests](/home/yan/src/quod/test/quod_ask_tests.erl):`-ask_test_/0-fun-20-/0:331` | plain failure asserted as reasoned |
| [10](quod-eunit-01.log:20455) | [quod_ask_tests](/home/yan/src/quod/test/quod_ask_tests.erl):`-ask_test_/0-fun-14-/0:337` | plain failure asserted as reasoned |
| [11](quod-eunit-01.log:20462) | [quod_ask_tests](/home/yan/src/quod/test/quod_ask_tests.erl):`-ask_test_/0-fun-9-/0:342` | automatic frames matched by fallback |
| [12](quod-eunit-01.log:20469) | [quod_ask_tests](/home/yan/src/quod/test/quod_ask_tests.erl):`-ask_test_/0-fun-7-/0:344` | automatic frames matched by fallback |
| [13](quod-eunit-01.log:20476) | [quod_ask_tests](/home/yan/src/quod/test/quod_ask_tests.erl):`-fresh_ledgers_single_target_uses_vector_receipt_test_/0-fun-12-/0` | plain failure asserted as reasoned |
| [14](quod-eunit-01.log:20483) | [quod_ask_tests](/home/yan/src/quod/test/quod_ask_tests.erl):`-signed_read_dependencies_test_/0-fun-5-/0` | plain failure asserted as reasoned |
| [15](quod-eunit-01.log:20490) | [quod_ask_tests](/home/yan/src/quod/test/quod_ask_tests.erl):`-independent_integration_test_/0-fun-3-/0:653` | plain failure asserted as reasoned |
| [16](quod-eunit-01.log:20497) | [quod_ask_tests](/home/yan/src/quod/test/quod_ask_tests.erl):`-independent_integration_test_/0-fun-2-/0:654` | plain failure asserted as reasoned |
| [17](quod-eunit-01.log:20504) | [quod_client_goal_ingress_tests](/home/yan/src/quod/test/quod_client_goal_ingress_tests.erl):`-signed_local_read_test_/0-fun-14-/0:170` | normalized plain failure asserted as reasoned |
| [18](quod-eunit-01.log:20597) | [quod_physics_tests](/home/yan/src/quod/test/quod_physics_tests.erl):`-m3a_shared_component_test_/0-fun-49-/0` | plain failure asserted as reasoned |
| [19](quod-eunit-01.log:20606) | [quod_physics_tests](/home/yan/src/quod/test/quod_physics_tests.erl):`-m3a_shared_projection_test_/0-fun-25-/0` | plain failure asserted as reasoned |
| [20](quod-eunit-01.log:20615) | [quod_physics_tests](/home/yan/src/quod/test/quod_physics_tests.erl):`-root_body_appearance_frame_test_/0-fun-5-/0` | plain failure asserted as reasoned |
| [21](quod-eunit-01.log:20624) | [quod_physics_tests](/home/yan/src/quod/test/quod_physics_tests.erl):`-first_host_and_complete_configuration_commit_together_test_/0-fun-4-/0: gallery-first-physics` | plain failure asserted as reasoned |
| [22](quod-eunit-01.log:20633) | [quod_physics_tests](/home/yan/src/quod/test/quod_physics_tests.erl):`-first_host_and_complete_configuration_commit_together_test_/0-fun-4-/0: workshop-first-physics` | plain failure asserted as reasoned |
| [23](quod-eunit-01.log:20642) | [quod_physics_tests](/home/yan/src/quod/test/quod_physics_tests.erl):`-m3a_frame_failure_isolates_world_test_/0-fun-26-/0: member` | plain failure asserted as reasoned |
| [24](quod-eunit-01.log:20651) | [quod_physics_tests](/home/yan/src/quod/test/quod_physics_tests.erl):`-live_source_authority_replacement_test_/0-fun-12-/0` | normalized plain failure asserted as reasoned |
| [25](quod-eunit-01.log:20763) | [quod_physics_tests](/home/yan/src/quod/test/quod_physics_tests.erl):`-live_source_lifecycle_test_/0-fun-21-/0: live-workshop` | normalized plain failure asserted as reasoned |
| [26](quod-eunit-01.log:20881) | [quod_physics_tests](/home/yan/src/quod/test/quod_physics_tests.erl):`-live_source_lifecycle_test_/0-fun-21-/0: live-observatory` | normalized plain failure asserted as reasoned |
| [27](quod-eunit-01.log:20999) | [quod_physics_tests](/home/yan/src/quod/test/quod_physics_tests.erl):`-live_source_missing_space_admission_test_/0-fun-9-/0` | plain failure asserted as reasoned |
| [28](quod-eunit-01.log:21008) | [quod_physics_tests](/home/yan/src/quod/test/quod_physics_tests.erl):`-live_source_withdrawal_after_reclassification_test_/0-fun-12-/0: space` | plain failure asserted as reasoned |
| [29](quod-eunit-01.log:21017) | [quod_physics_tests](/home/yan/src/quod/test/quod_physics_tests.erl):`-live_source_withdrawal_after_reclassification_test_/0-fun-12-/0: untyped` | plain failure asserted as reasoned |
| [30](quod-eunit-01.log:21026) | [quod_physics_tests](/home/yan/src/quod/test/quod_physics_tests.erl):`-supported_geometry_signed_edit_test_/0-fun-11-/0: box` | normalized plain failure asserted as reasoned |
| [31](quod-eunit-01.log:21143) | [quod_physics_tests](/home/yan/src/quod/test/quod_physics_tests.erl):`-supported_geometry_signed_edit_test_/0-fun-11-/0: ball` | normalized plain failure asserted as reasoned |
| [32](quod-eunit-01.log:21258) | [quod_physics_tests](/home/yan/src/quod/test/quod_physics_tests.erl):`-supported_geometry_signed_edit_test_/0-fun-11-/0: capsule` | normalized plain failure asserted as reasoned |
| [33](quod-eunit-01.log:21376) | [quod_physics_tests](/home/yan/src/quod/test/quod_physics_tests.erl):`-supported_geometry_signed_edit_test_/0-fun-11-/0: convex` | normalized plain failure asserted as reasoned |
| [34](quod-eunit-01.log:21491) | [quod_physics_tests](/home/yan/src/quod/test/quod_physics_tests.erl):`-supported_geometry_signed_edit_test_/0-fun-11-/0: dynamic_ball` | normalized plain failure asserted as reasoned |
| [35](quod-eunit-01.log:21608) | [quod_physics_tests](/home/yan/src/quod/test/quod_physics_tests.erl):`-supported_geometry_signed_edit_test_/0-fun-11-/0: controlled_capsule` | normalized plain failure asserted as reasoned |
| [36](quod-eunit-01.log:21725) | [quod_physics_tests](/home/yan/src/quod/test/quod_physics_tests.erl):`-supported_geometry_signed_edit_test_/0-fun-11-/0: dynamic_convex` | normalized plain failure asserted as reasoned |
| [37](quod-eunit-01.log:21841) | [quod_physics_tests](/home/yan/src/quod/test/quod_physics_tests.erl):`-supported_geometry_signed_edit_test_/0-fun-11-/0: parts` | normalized plain failure asserted as reasoned |
| [38](quod-eunit-01.log:21956) | [quod_physics_tests](/home/yan/src/quod/test/quod_physics_tests.erl):`-supported_geometry_signed_edit_test_/0-fun-11-/0: surface` | normalized plain failure asserted as reasoned |
| [39](quod-eunit-01.log:22073) | [quod_physics_tests](/home/yan/src/quod/test/quod_physics_tests.erl):`-numeric_geometry_and_hinge_refusals_test_/0-fun-27-/0` | plain failure asserted as reasoned |
| [40](quod-eunit-01.log:22082) | [quod_physics_tests](/home/yan/src/quod/test/quod_physics_tests.erl):`-system_physics_world_policy_test_/0-fun-13-/0: physics-policy-earth` | normalized plain failure asserted as reasoned |
| [41](quod-eunit-01.log:22203) | [quod_physics_tests](/home/yan/src/quod/test/quod_physics_tests.erl):`-system_physics_world_policy_test_/0-fun-13-/0: physics-policy-moon` | normalized plain failure asserted as reasoned |
| [42](quod-eunit-01.log:22324) | [quod_physics_tests](/home/yan/src/quod/test/quod_physics_tests.erl):`-signed_live_body_predicate_test_/0-fun-13-/0` | normalized plain failure asserted as reasoned |
| [43](quod-eunit-01.log:22445) | [quod_physics_tests](/home/yan/src/quod/test/quod_physics_tests.erl):`-hot_control_policy_reasons_test_/0-fun-12-/0` | normalized plain failure asserted as reasoned |
| [44](quod-eunit-01.log:22606) | [quod_physics_tests](/home/yan/src/quod/test/quod_physics_tests.erl):`-signed_motion_query_owner_test_/0-fun-18-/0` | normalized plain failure asserted as reasoned |
| [45](quod-eunit-01.log:22741) | [quod_physics_tests](/home/yan/src/quod/test/quod_physics_tests.erl):`-signed_control_releases_only_successful_proof_test_/0-fun-25-/0` | normalized plain failure asserted as reasoned |
| [46](quod-eunit-01.log:22939) | [quod_physics_tests](/home/yan/src/quod/test/quod_physics_tests.erl):`-grounded_jump_and_ceiling_test_/0-fun-16-/0: floor` | normalized plain failure asserted as reasoned |
| [47](quod-eunit-01.log:23149) | [quod_physics_tests](/home/yan/src/quod/test/quod_physics_tests.erl):`-grounded_jump_and_ceiling_test_/0-fun-16-/0: ceiling` | normalized plain failure asserted as reasoned |
| [48](quod-eunit-01.log:23350) | [quod_physics_tests](/home/yan/src/quod/test/quod_physics_tests.erl):`-grounded_jump_and_ceiling_test_/0-fun-16-/0: air` | normalized plain failure asserted as reasoned |
| [49](quod-eunit-01.log:23557) | [quod_physics_tests](/home/yan/src/quod/test/quod_physics_tests.erl):`-signed_landing_reposition_and_feedback_test_/0-fun-15-/0` | normalized plain failure asserted as reasoned |
| [50](quod-eunit-01.log:23760) | [quod_physics_tests](/home/yan/src/quod/test/quod_physics_tests.erl):`-retained_activation_before_first_send_is_resolve_only_after_owner_loss_test_/0-fun-9-/0` | normalized plain failure asserted as reasoned |
| [51](quod-eunit-01.log:24003) | [quod_physics_tests](/home/yan/src/quod/test/quod_physics_tests.erl):`-explicit_activation_cancellation_test_/0-fun-1-/0: never_submitted` | normalized plain failure asserted as reasoned |
| [52](quod-eunit-01.log:24373) | [quod_physics_tests](/home/yan/src/quod/test/quod_physics_tests.erl):`-explicit_activation_cancellation_test_/0-fun-1-/0: prepared_before_cancellation` | normalized plain failure asserted as reasoned |
| [53](quod-eunit-01.log:24746) | [quod_physics_tests](/home/yan/src/quod/test/quod_physics_tests.erl):`-explicit_activation_cancellation_test_/0-fun-1-/0: activation_wins` | normalized plain failure asserted as reasoned |
| [54](quod-eunit-01.log:25117) | [quod_physics_tests](/home/yan/src/quod/test/quod_physics_tests.erl):`-explicit_activation_cancellation_test_/0-fun-1-/0: disabled` | normalized plain failure asserted as reasoned |
| [55](quod-eunit-01.log:25490) | [quod_physics_tests](/home/yan/src/quod/test/quod_physics_tests.erl):`-obstructed_door_signed_transition_test_/0-fun-12-/0` | normalized plain failure asserted as reasoned |
| [56](quod-eunit-01.log:25734) | [quod_physics_tests](/home/yan/src/quod/test/quod_physics_tests.erl):`-pending_custody_and_delayed_sample_cannot_finish_new_close_test_/0-fun-16-/0` | normalized plain failure asserted as reasoned |
| [57](quod-eunit-01.log:27092) | [quod_physics_tests](/home/yan/src/quod/test/quod_physics_tests.erl):`-signed_chair_push_checkpoint_and_recovery_test_/0-fun-36-/0` | normalized plain failure asserted as reasoned |
| [58](quod-eunit-01.log:27303) | [quod_physics_tests](/home/yan/src/quod/test/quod_physics_tests.erl):`-chair_edit_races_prepared_checkpoint_test_/0-fun-9-/0` | plain failure asserted as reasoned |
| [59](quod-eunit-01.log:27312) | [quod_physics_tests](/home/yan/src/quod/test/quod_physics_tests.erl):`-chair_unknown_checkpoint_custody_is_not_resubmitted_test_/0-fun-16-/0` | plain failure asserted as reasoned |
| [60](quod-eunit-01.log:27321) | [quod_physics_tests](/home/yan/src/quod/test/quod_physics_tests.erl):`-authored_nonbox_edit_invalidates_rest_checkpoint_test_/0-fun-9-/0: ball` | plain failure asserted as reasoned |
| [61](quod-eunit-01.log:27330) | [quod_physics_tests](/home/yan/src/quod/test/quod_physics_tests.erl):`-authored_nonbox_edit_invalidates_rest_checkpoint_test_/0-fun-9-/0: compound` | plain failure asserted as reasoned |
| [62](quod-eunit-01.log:27339) | [quod_physics_tests](/home/yan/src/quod/test/quod_physics_tests.erl):`-hinged_receiver_completion_is_atomic_test_/0-fun-1-/0: commit` | plain failure asserted as reasoned |
| [63](quod-eunit-01.log:27348) | [quod_physics_tests](/home/yan/src/quod/test/quod_physics_tests.erl):`-hinged_receiver_completion_is_atomic_test_/0-fun-1-/0: denied` | plain failure asserted as reasoned |
| [64](quod-eunit-01.log:27357) | [quod_physics_tests](/home/yan/src/quod/test/quod_physics_tests.erl):`-hinged_receiver_completion_is_atomic_test_/0-fun-1-/0: rollback` | plain failure asserted as reasoned |
| [65](quod-eunit-01.log:27366) | [quod_physics_tests](/home/yan/src/quod/test/quod_physics_tests.erl):`-hinged_receiver_completion_is_atomic_test_/0-fun-1-/0: conflict` | plain failure asserted as reasoned |
| [66](quod-eunit-01.log:27375) | [quod_physics_tests](/home/yan/src/quod/test/quod_physics_tests.erl):`-shared_fixed_support_moves_atomically_test_/0-fun-12-/0` | normalized plain failure asserted as reasoned |
| [67](quod-eunit-01.log:27500) | [quod_physics_tests](/home/yan/src/quod/test/quod_physics_tests.erl):`-hinged_command_edit_fences_signed_sample_test_/0-fun-8-/0: before_store` | normalized plain failure asserted as reasoned |
| [68](quod-eunit-01.log:28868) | [quod_physics_tests](/home/yan/src/quod/test/quod_physics_tests.erl):`-hinged_command_edit_fences_signed_sample_test_/0-fun-8-/0: after_store` | normalized plain failure asserted as reasoned |
| [69](quod-eunit-01.log:29192) | [quod_physics_tests](/home/yan/src/quod/test/quod_physics_tests.erl):`-authored_hinged_obstruction_and_permissions_test_/0-fun-9-/0` | normalized plain failure asserted as reasoned |
| [70](quod-eunit-01.log:29313) | [quod_physics_tests](/home/yan/src/quod/test/quod_physics_tests.erl):`-finished_hinged_group_move_can_close_again_test_/0-fun-9-/0` | plain failure asserted as reasoned |
| [71](quod-eunit-01.log:29322) | [quod_prolog_tests](/home/yan/src/quod/test/quod_prolog_tests.erl):`-native_execution_uses_ordinary_acl_and_commit_test_/0-fun-8-/0` | plain failure asserted as reasoned |
| [72](quod-eunit-01.log:29331) | [quod_prolog_tests](/home/yan/src/quod/test/quod_prolog_tests.erl):`-native_async_execute_rejects_a_replaced_target_test_/0-fun-3-/0` | plain failure asserted as reasoned |
| [73](quod-eunit-01.log:29340) | [quod_prolog_tests](/home/yan/src/quod/test/quod_prolog_tests.erl):`-native_caller_loss_cancels_its_proof_without_stopping_the_engine_test_/0-fun-4-/0` | plain failure asserted as reasoned |
| [74](quod-eunit-01.log:29349) | [quod_prolog_tests](/home/yan/src/quod/test/quod_prolog_tests.erl):`-owned_async_execute_preserves_absolute_deadline_test_/0-fun-5-/0` | plain failure asserted as reasoned |
| [75](quod-eunit-01.log:29358) | [quod_prolog_tests](/home/yan/src/quod/test/quod_prolog_tests.erl):`-t_unknown_fails/1-fun-2-/0` | plain failure asserted as reasoned |
| [76](quod-eunit-01.log:29365) | [quod_prolog_tests](/home/yan/src/quod/test/quod_prolog_tests.erl):`-t_explicit_failure_reason_and_internal_bare_fail/1-fun-2-/0` | explicit list differs |
| [77](quod-eunit-01.log:29372) | [quod_prolog_tests](/home/yan/src/quod/test/quod_prolog_tests.erl):`-t_occ_reject/1-fun-3-/0` | plain failure asserted as reasoned |
| [78](quod-eunit-01.log:29379) | [quod_prolog_tests](/home/yan/src/quod/test/quod_prolog_tests.erl):`-t_policy_self_seal/1-fun-5-/0` | plain failure asserted as reasoned |
| [79](quod-eunit-01.log:29386) | [quod_prolog_tests](/home/yan/src/quod/test/quod_prolog_tests.erl):`-t_batch_apply/1-fun-8-/0` | plain failure asserted as reasoned |
| [80](quod-eunit-01.log:29393) | [quod_prolog_tests](/home/yan/src/quod/test/quod_prolog_tests.erl):`-t_same_block_read_after_write/1-fun-4-/0` | plain failure asserted as reasoned |
| [81](quod-eunit-01.log:29400) | [quod_prolog_tests](/home/yan/src/quod/test/quod_prolog_tests.erl):`-outcome_unknown_timeout_test_/0-fun-11-/0` | plain failure asserted as reasoned |
| [82](quod-eunit-01.log:29407) | [quod_prolog_tests](/home/yan/src/quod/test/quod_prolog_tests.erl):`-unavailable_append_reply_waits_for_outcome_unknown_test_/0-fun-12-/0` | plain failure asserted as reasoned |
| [83](quod-eunit-01.log:29414) | [quod_prolog_tests](/home/yan/src/quod/test/quod_prolog_tests.erl):`-t_signed_operation_uses_the_same_content_verdict_path/1-fun-8-/0` | plain failure asserted as reasoned |
| [84](quod-eunit-01.log:29421) | [quod_prolog_tests](/home/yan/src/quod/test/quod_prolog_tests.erl):`-t_live_reject_emits_event/1-fun-5-/0` | plain failure asserted as reasoned |
| [85](quod-eunit-01.log:29428) | [quod_runtime_tests](/home/yan/src/quod/test/quod_runtime_tests.erl):`-subscribed_reaction_observes_event_only_atomic_resolve_once_test_/0-fun-9-/0` | plain failure asserted as reasoned |
| [86](quod-eunit-01.log:29435) | [quod_runtime_tests](/home/yan/src/quod/test/quod_runtime_tests.erl):`-local_explicit_event_repeats_without_mutating_facts_test_/0-fun-7-/0` | plain failure asserted as reasoned |
| [87](quod-eunit-01.log:29442) | [quod_runtime_tests](/home/yan/src/quod/test/quod_runtime_tests.erl):`-failed_resource_is_not_installed_by_later_events_test_/0-fun-9-/0` | plain failure asserted as reasoned |
| [88](quod-eunit-01.log:29451) | [quod_transaction_predicates_tests](/home/yan/src/quod/test/quod_transaction_predicates_tests.erl):`failure_reasons_survive_rollback_test/0` | explicit list differs |
| [89](quod-eunit-01.log:29459) | [quod_agent_custody_tests](/home/yan/src/quod/test/quod_agent_custody_tests.erl):`-prepared_observation_commits_custody_report_and_assignment_once_test_/0-fun-1-/0` | plain failure asserted as reasoned |
| [90](quod-eunit-01.log:29468) | [quod_agent_custody_tests](/home/yan/src/quod/test/quod_agent_custody_tests.erl):`-unavailable_custody_still_records_the_observation_test_/0-fun-1-/0` | plain failure asserted as reasoned |
| [91](quod-eunit-01.log:29477) | [quod_agent_custody_tests](/home/yan/src/quod/test/quod_agent_custody_tests.erl):`-recovery_acl_external_query_is_rejected_test_/0-fun-1-/0` | plain failure asserted as reasoned |
| [92](quod-eunit-01.log:29486) | [quod_agent_custody_tests](/home/yan/src/quod/test/quod_agent_custody_tests.erl):`-worker_refuses_custody_for_wrong_target_anchor_test_/0-fun-4-/0` | normalized plain failure asserted as reasoned |
| [93](quod-eunit-01.log:29592) | [quod_agent_hosting_tests](/home/yan/src/quod/test/quod_agent_hosting_tests.erl):`-class_owner_hosting_transitions_test_/0-fun-19-/0` | normalized plain failure asserted as reasoned |
| [94](quod-eunit-01.log:29795) | [quod_agent_hosting_tests](/home/yan/src/quod/test/quod_agent_hosting_tests.erl):`-class_owner_signing_preserves_storage_and_policy_boundaries_test_/0-fun-15-/0` | plain failure asserted as reasoned |
| [95](quod-eunit-01.log:29804) | [quod_agent_hosting_tests](/home/yan/src/quod/test/quod_agent_hosting_tests.erl):`-projected_work_wakes_after_real_queue_capacity_release_test_/0-fun-6-/0` | plain failure asserted as reasoned |
| [96](quod-eunit-01.log:29813) | [quod_agent_hosting_tests](/home/yan/src/quod/test/quod_agent_hosting_tests.erl):`-hosted_reactions_and_incarnation_recovery_test_/0-fun-0-/0` | plain failure asserted as reasoned |
| [97](quod-eunit-01.log:29822) | [quod_agent_hosting_tests](/home/yan/src/quod/test/quod_agent_hosting_tests.erl):`-hosted_agents_exchange_committed_events_test_/0-fun-0-/0` | plain failure asserted as reasoned |
| [98](quod-eunit-01.log:29831) | [quod_agent_hosting_tests](/home/yan/src/quod/test/quod_agent_hosting_tests.erl):`-retained_request_uses_original_bytes_and_timeout_identity_test_/0-fun-8-/0: success` | normalized plain failure asserted as reasoned |
| [99](quod-eunit-01.log:29928) | [quod_agent_hosting_tests](/home/yan/src/quod/test/quod_agent_hosting_tests.erl):`-retained_request_uses_original_bytes_and_timeout_identity_test_/0-fun-8-/0: stale_key` | test helper calls element on plain failure |
| [100](quod-eunit-01.log:29955) | [quod_agent_hosting_tests](/home/yan/src/quod/test/quod_agent_hosting_tests.erl):`-retained_request_uses_original_bytes_and_timeout_identity_test_/0-fun-8-/0: timeout` | test helper calls element on plain failure |
| [101](quod-eunit-01.log:29982) | [quod_agent_hosting_tests](/home/yan/src/quod/test/quod_agent_hosting_tests.erl):`-fipa_action_and_reply_commit_together_test_/0-fun-0-/0` | normalized plain failure asserted as reasoned |
| [102](quod-eunit-01.log:29991) | [quod_agent_hosting_tests](/home/yan/src/quod/test/quod_agent_hosting_tests.erl):`-fipa_rejected_reply_rolls_back_domain_action_test_/0-fun-0-/0` | plain failure asserted as reasoned |
| [103](quod-eunit-01.log:30000) | [quod_agent_hosting_tests](/home/yan/src/quod/test/quod_agent_hosting_tests.erl):`-fipa_unstarted_request_survives_restart_without_event_replay_test_/0-fun-0-/0` | plain failure asserted as reasoned |
| [104](quod-eunit-01.log:30009) | [quod_agent_hosting_tests](/home/yan/src/quod/test/quod_agent_hosting_tests.erl):`-fipa_request_continues_after_restart_during_proof_test_/0-fun-0-/0` | plain failure asserted as reasoned |
| [105](quod-eunit-01.log:30018) | [quod_agent_hosting_tests](/home/yan/src/quod/test/quod_agent_hosting_tests.erl):`-fipa_request_continues_after_key_rotation_during_proof_test_/0-fun-0-/0` | plain failure asserted as reasoned |
| [106](quod-eunit-01.log:30027) | [quod_agent_hosting_tests](/home/yan/src/quod/test/quod_agent_hosting_tests.erl):`-fipa_request_continues_after_runtime_loss_with_durable_custody_test_/0-fun-0-/0` | plain failure asserted as reasoned |
| [107](quod-eunit-01.log:30036) | [quod_agent_hosting_tests](/home/yan/src/quod/test/quod_agent_hosting_tests.erl):`-fipa_competing_completions_commit_once_test_/0-fun-0-/0` | plain failure asserted as reasoned |
| [108](quod-eunit-01.log:30045) | [quod_agent_hosting_tests](/home/yan/src/quod/test/quod_agent_hosting_tests.erl):`-unexpected_child_exit_enters_ontology_reaction_test_/0-fun-3-/0` | plain failure asserted as reasoned |
| [109](quod-eunit-01.log:30054) | [quod_agent_hosting_tests](/home/yan/src/quod/test/quod_agent_hosting_tests.erl):`-observation_during_restoration_survives_pending_installation_test_/0-fun-3-/0` | plain failure asserted as reasoned |
| [110](quod-eunit-01.log:30063) | [quod_agent_hosting_tests](/home/yan/src/quod/test/quod_agent_hosting_tests.erl):`-physical_loss_drives_signed_policy_and_host_activation_test_/0-fun-3-/0: graceful` | plain failure asserted as reasoned |
| [111](quod-eunit-01.log:30092) | [quod_agent_hosting_tests](/home/yan/src/quod/test/quod_agent_hosting_tests.erl):`-physical_loss_drives_signed_policy_and_host_activation_test_/0-fun-3-/0: abrupt` | plain failure asserted as reasoned |
| [112](quod-eunit-01.log:30101) | [quod_agent_hosting_tests](/home/yan/src/quod/test/quod_agent_hosting_tests.erl):`-node_execution_policy_installs_through_ordinary_signed_goal_test_/0-fun-6-/0` | normalized plain failure asserted as reasoned |
| [113](quod-eunit-01.log:30220) | [quod_agent_hosting_tests](/home/yan/src/quod/test/quod_agent_hosting_tests.erl):`-installed_handler_observation_uses_actual_owner_test_/0-fun-1-/0` | plain failure asserted as reasoned |
| [114](quod-eunit-01.log:30229) | [quod_agent_hosting_tests](/home/yan/src/quod/test/quod_agent_hosting_tests.erl):`-node_executor_requires_exact_delegation_at_execution_test_/0-fun-0-/0` | normalized plain failure asserted as reasoned |
| [115](quod-eunit-01.log:30352) | [quod_agent_hosting_tests](/home/yan/src/quod/test/quod_agent_hosting_tests.erl):`-signed_node_request_context_survives_foreign_scope_test_/0-fun-3-/0` | normalized plain failure asserted as reasoned |
| [116](quod-eunit-01.log:30470) | [quod_agent_hosting_tests](/home/yan/src/quod/test/quod_agent_hosting_tests.erl):`-failed_staged_assignment_cannot_install_hosted_process_test_/0-fun-6-/0` | plain failure asserted as reasoned |
| [117](quod-eunit-01.log:30479) | [quod_agent_hosting_tests](/home/yan/src/quod/test/quod_agent_hosting_tests.erl):`-agent_queue_has_aggregate_byte_bound_and_reclaims_on_discard_test_/0-fun-9-/0` | plain failure asserted as reasoned |
| [118](quod-eunit-01.log:30488) | [quod_agent_hosting_tests](/home/yan/src/quod/test/quod_agent_hosting_tests.erl):`-atomic_recovery_commits_one_diff_and_restores_projection_test_/0-fun-1-/0` | plain failure asserted as reasoned |
| [119](quod-eunit-01.log:30497) | [quod_agent_hosting_tests](/home/yan/src/quod/test/quod_agent_hosting_tests.erl):`-failed_atomic_recovery_does_not_commit_its_report_test_/0-fun-1-/0` | normalized plain failure asserted as reasoned |
| [120](quod-eunit-01.log:30711) | [quod_agent_hosting_tests](/home/yan/src/quod/test/quod_agent_hosting_tests.erl):`-host_move_withdraws_child_and_revokes_released_signature_test_/0-fun-0-/0` | plain failure asserted as reasoned |
| [121](quod-eunit-01.log:30720) | [quod_agent_hosting_tests](/home/yan/src/quod/test/quod_agent_hosting_tests.erl):`-running_request_deadline_kills_worker_without_claiming_rejection_test_/0-fun-4-/0` | plain failure asserted as reasoned |
| [122](quod-eunit-01.log:30729) | [quod_agent_reaction_tests](/home/yan/src/quod/test/quod_agent_reaction_tests.erl):`-ordinary_owned_reactions_use_signed_goal_admission_test_/0-fun-12-/0` | plain failure asserted as reasoned |
| [123](quod-eunit-01.log:30738) | [quod_agent_recovery_tests](/home/yan/src/quod/test/quod_agent_recovery_tests.erl):`-host_loss_drains_more_than_executor_capacity_without_collapsing_test_/0-fun-2-/0` | plain failure asserted as reasoned |
| [124](quod-eunit-01.log:30767) | [quod_agent_recovery_tests](/home/yan/src/quod/test/quod_agent_recovery_tests.erl):`-runtime_restart_after_host_loss_recovers_through_expired_contact_test_/0-fun-8-/0` | plain failure asserted as reasoned |
| [125](quod-eunit-01.log:30796) | [quod_class_permissions_tests](/home/yan/src/quod/test/quod_class_permissions_tests.erl):`signed_foreign_guard/0` | normalized plain failure asserted as reasoned |
| [126](quod-eunit-01.log:30926) | [quod_class_permissions_tests](/home/yan/src/quod/test/quod_class_permissions_tests.erl):`signed_boundaries/0` | normalized plain failure asserted as reasoned |
| [127](quod-eunit-01.log:31040) | [quod_constructor_tests](/home/yan/src/quod/test/quod_constructor_tests.erl):`signed_qualified_class/0` | normalized plain failure asserted as reasoned |
| [128](quod-eunit-01.log:31160) | [quod_constructor_tests](/home/yan/src/quod/test/quod_constructor_tests.erl):`signed_owner/0` | normalized plain failure asserted as reasoned |
| [129](quod-eunit-01.log:31281) | [quod_controller_tests](/home/yan/src/quod/test/quod_controller_tests.erl):`-preferences_use_existing_instruction_and_form_test_/0-fun-13-/0` | plain failure asserted as reasoned |
| [130](quod-eunit-01.log:31290) | [quod_controller_tests](/home/yan/src/quod/test/quod_controller_tests.erl):`-shared_mapping_rejects_conflicts_and_unknown_outputs_test_/0-fun-4-/0` | plain failure asserted as reasoned |
| [131](quod-eunit-01.log:31299) | [quod_create_root_tests](/home/yan/src/quod/test/quod_create_root_tests.erl):`-t_create_root/1-fun-7-/0` | plain failure asserted as reasoned |
| [132](quod-eunit-01.log:31306) | [quod_e2e_tests](/home/yan/src/quod/test/quod_e2e_tests.erl):`-t_write_read/1-fun-6-/0` | plain failure asserted as reasoned |
| [133](quod-eunit-01.log:31313) | [quod_e2e_tests](/home/yan/src/quod/test/quod_e2e_tests.erl):`-t_prolog_restart_rebuild/1-fun-3-/0` | plain failure asserted as reasoned |
| [134](quod-eunit-01.log:31320) | [quod_e2e_tests](/home/yan/src/quod/test/quod_e2e_tests.erl):`-t_failing_proofs_no_ets_leak/1-fun-4-/0` | plain failure asserted as reasoned |
| [135](quod-eunit-01.log:31327) | [quod_gui_components_tests](/home/yan/src/quod/test/quod_gui_components_tests.erl):`-remaining_controls_preserve_binding_and_atomic_refusal_test_/0-fun-12-/0` | normalized plain failure asserted as reasoned |
| [136](quod-eunit-01.log:31472) | [quod_gui_components_tests](/home/yan/src/quod/test/quod_gui_components_tests.erl):`-composition_uses_inherited_defaults_and_only_binds_inputs_test_/0-fun-19-/0` | normalized plain failure asserted as reasoned |
| [137](quod-eunit-01.log:31652) | [quod_gui_components_tests](/home/yan/src/quod/test/quod_gui_components_tests.erl):`-input_variants_keep_typed_binding_and_rollback_test_/0-fun-17-/0` | normalized plain failure asserted as reasoned |
| [138](quod-eunit-01.log:31867) | [quod_gui_components_tests](/home/yan/src/quod/test/quod_gui_components_tests.erl):`-elaborate_form_uses_one_vocabulary_projection_test_/0-fun-12-/0` | normalized plain failure asserted as reasoned |
| [139](quod-eunit-01.log:32290) | [quod_gui_components_tests](/home/yan/src/quod/test/quod_gui_components_tests.erl):`-forms_use_the_same_signed_ontology_path_test_/0-fun-2-/0` | normalized plain failure asserted as reasoned |
| [140](quod-eunit-01.log:32464) | [quod_gui_examples_tests](/home/yan/src/quod/test/quod_gui_examples_tests.erl):`examples/0` | normalized plain failure asserted as reasoned |
| [141](quod-eunit-01.log:32698) | [quod_gui_examples_tests](/home/yan/src/quod/test/quod_gui_examples_tests.erl):`world_library/0` | normalized plain failure asserted as reasoned |
| [142](quod-eunit-01.log:32835) | [quod_gui_examples_tests](/home/yan/src/quod/test/quod_gui_examples_tests.erl):`-voxel_form_creates_user_owned_terrain_and_rejects_a_dig_stale_submission_test_/0-fun-24-/0` | normalized plain failure asserted as reasoned |
| [143](quod-eunit-01.log:33128) | [quod_gui_hud_tests](/home/yan/src/quod/test/quod_gui_hud_tests.erl):`-hud_composes_standing_context_and_contributions_test_/0-fun-30-/0` | plain failure asserted as reasoned |
| [144](quod-eunit-01.log:33137) | [quod_gui_hud_tests](/home/yan/src/quod/test/quod_gui_hud_tests.erl):`-hud_space_owner_authority_and_storing_acl_test_/0-fun-3-/0` | plain failure asserted as reasoned |
| [145](quod-eunit-01.log:33146) | [quod_gui_menu_tests](/home/yan/src/quod/test/quod_gui_menu_tests.erl):`-icon_bytes_are_public_signed_facts_test_/0-fun-12-/0` | normalized plain failure asserted as reasoned |
| [146](quod-eunit-01.log:33294) | [quod_gui_menu_tests](/home/yan/src/quod/test/quod_gui_menu_tests.erl):`-release_terms_use_the_existing_signed_edit_gate_test_/0-fun-5-/0` | plain failure asserted as reasoned |
| [147](quod-eunit-01.log:33303) | [quod_gui_menu_tests](/home/yan/src/quod/test/quod_gui_menu_tests.erl):`-interior_walls_use_the_shared_extent_test_/0-fun-12-/0` | plain failure asserted as reasoned |
| [148](quod-eunit-01.log:33312) | [quod_gui_menu_tests](/home/yan/src/quod/test/quod_gui_menu_tests.erl):`-one_thing_is_read_in_another_mode_test_/0-fun-9-/0` | test helper handles only reasoned failure |
| [149](quod-eunit-01.log:33356) | [quod_gui_menu_tests](/home/yan/src/quod/test/quod_gui_menu_tests.erl):`-overflow_nests_under_more_and_keeps_pins_test_/0-fun-22-/0` | plain failure asserted as reasoned |
| [150](quod-eunit-01.log:33365) | [quod_gui_operations_tests](/home/yan/src/quod/test/quod_gui_operations_tests.erl):`-prebound_creation_output_is_refused_test_/0-fun-1-/0` | test helper calls element on plain failure |
| [151](quod-eunit-01.log:33403) | [quod_gui_operations_tests](/home/yan/src/quod/test/quod_gui_operations_tests.erl):`-execution_preserves_authored_output_aliases_test_/0-fun-5-/0` | test helper calls element on plain failure |
| [152](quod-eunit-01.log:33441) | [quod_gui_operations_tests](/home/yan/src/quod/test/quod_gui_operations_tests.erl):`-offered_creation_and_instance_operation_test_/0-fun-14-/0` | plain failure asserted as reasoned |
| [153](quod-eunit-01.log:33450) | [quod_gui_operations_tests](/home/yan/src/quod/test/quod_gui_operations_tests.erl):`-binding_refuses_invalid_or_changed_contract_test_/0-fun-5-/0` | test helper calls element on plain failure |
| [154](quod-eunit-01.log:33492) | [quod_gui_operations_tests](/home/yan/src/quod/test/quod_gui_operations_tests.erl):`-foreign_recipe_compiles_at_owner_and_executes_at_storage_test_/0-fun-6-/0` | plain failure asserted as reasoned |
| [155](quod-eunit-01.log:33501) | [quod_gui_operations_tests](/home/yan/src/quod/test/quod_gui_operations_tests.erl):`-discovery_is_read_only_even_in_execute_test_/0-fun-3-/0` | plain failure asserted as reasoned |
| [156](quod-eunit-01.log:33510) | [quod_gui_question_tests](/home/yan/src/quod/test/quod_gui_question_tests.erl):`-native_scope_is_read_only_and_keeps_original_request_test_/0-fun-10-/0` | normalized plain failure asserted as reasoned |
| [157](quod-eunit-01.log:33641) | [quod_gui_question_tests](/home/yan/src/quod/test/quod_gui_question_tests.erl):`-native_presentation_uses_original_scope_and_closed_effect_codec_test_/0-fun-23-/0` | normalized plain failure asserted as reasoned |
| [158](quod-eunit-01.log:33769) | [quod_gui_question_tests](/home/yan/src/quod/test/quod_gui_question_tests.erl):`-live_opening_commits_question_hud_and_presentation_together_test_/0-fun-38-/0` | normalized plain failure asserted as reasoned |
| [159](quod-eunit-01.log:33892) | [quod_gui_question_tests](/home/yan/src/quod/test/quod_gui_question_tests.erl):`-accepted_question_transitions_use_signed_atomic_owners_test_/0-fun-60-/0` | normalized plain failure asserted as reasoned |
| [160](quod-eunit-01.log:34072) | [quod_gui_question_tests](/home/yan/src/quod/test/quod_gui_question_tests.erl):`-committed_answer_automatically_completes_test_/0-fun-24-/0` | normalized plain failure asserted as reasoned |
| [161](quod-eunit-01.log:34673) | [quod_gui_stage1_tests](/home/yan/src/quod/test/quod_gui_stage1_tests.erl):`-authored_creation_recovery_test_/0-fun-10-/0: ordinary` | plain failure asserted as reasoned |
| [162](quod-eunit-01.log:34682) | [quod_gui_stage1_tests](/home/yan/src/quod/test/quod_gui_stage1_tests.erl):`-authored_creation_recovery_test_/0-fun-10-/0: atomic` | plain failure asserted as reasoned |
| [163](quod-eunit-01.log:34691) | [quod_gui_stage1_tests](/home/yan/src/quod/test/quod_gui_stage1_tests.erl):`-non_space_binding_and_updates_test_/0-fun-5-/0` | plain failure asserted as reasoned |
| [164](quod-eunit-01.log:34700) | [quod_lifecycle_single_path_tests](/home/yan/src/quod/test/quod_lifecycle_single_path_tests.erl):`-terms_creation_preserves_clauses_test_/0-fun-7-/0` | effect journal treats absence as unavailable |
| [165](quod-eunit-01.log:34715) | [quod_lifecycle_single_path_tests](/home/yan/src/quod/test/quod_lifecycle_single_path_tests.erl):`-creation_clauses_regression_test_/0-fun-1-/0: prepared clauses survive journal restart` | effect journal treats absence as unavailable |
| [166](quod-eunit-01.log:34742) | [quod_lifecycle_single_path_tests](/home/yan/src/quod/test/quod_lifecycle_single_path_tests.erl):`-creation_clauses_regression_test_/0-fun-1-/0: root entry ACL remains required` | effect journal treats absence as unavailable |
| [167](quod-eunit-01.log:34757) | [quod_lifecycle_single_path_tests](/home/yan/src/quod/test/quod_lifecycle_single_path_tests.erl):`-creation_clauses_regression_test_/0-fun-1-/0: failed policy prepares nothing` | effect journal treats absence as unavailable |
| [168](quod-eunit-01.log:34772) | [quod_lifecycle_single_path_tests](/home/yan/src/quod/test/quod_lifecycle_single_path_tests.erl):`-creation_clauses_regression_test_/0-fun-1-/0: false postcondition refuses` | effect journal treats absence as unavailable |
| [169](quod-eunit-01.log:34787) | [quod_lifecycle_single_path_tests](/home/yan/src/quod/test/quod_lifecycle_single_path_tests.erl):`-material_admission_uses_committed_root_policy_test_/0-fun-13-/0` | effect journal treats absence as unavailable |
| [170](quod-eunit-01.log:34822) | [quod_lifecycle_single_path_tests](/home/yan/src/quod/test/quod_lifecycle_single_path_tests.erl):`-default_lobby_physics_startup_test_/0-fun-30-/0` | setup: already_started |
| [171](quod-eunit-01.log:34848) | [quod_lifecycle_single_path_tests](/home/yan/src/quod/test/quod_lifecycle_single_path_tests.erl):`-m1a_guarded_source_test_/0-fun-4-/0` | setup: already_started |
| [172](quod-eunit-01.log:34873) | [quod_lifecycle_single_path_tests](/home/yan/src/quod/test/quod_lifecycle_single_path_tests.erl):`-m1a_signup_terms_test_/0-fun-7-/0` | setup: already_started |
| [173](quod-eunit-01.log:34898) | [quod_lifecycle_single_path_tests](/home/yan/src/quod/test/quod_lifecycle_single_path_tests.erl):`-m1a_seven_foundations_test_/0-fun-6-/0` | setup: already_started |
| [174](quod-eunit-01.log:34923) | [quod_lifecycle_single_path_tests](/home/yan/src/quod/test/quod_lifecycle_single_path_tests.erl):`-automatic_founder_enrollment_and_restart_test_/0-fun-9-/0` | setup: already_started |
| [175](quod-eunit-01.log:34949) | [quod_lifecycle_single_path_tests](/home/yan/src/quod/test/quod_lifecycle_single_path_tests.erl):`-node_enrollment_crash_custody_test_/0-fun-1-/0: before_send` | setup: already_started |
| [176](quod-eunit-01.log:34974) | [quod_lifecycle_single_path_tests](/home/yan/src/quod/test/quod_lifecycle_single_path_tests.erl):`-node_enrollment_crash_custody_test_/0-fun-1-/0: after_commit` | setup: already_started |
| [177](quod-eunit-01.log:34999) | [quod_lifecycle_single_path_tests](/home/yan/src/quod/test/quod_lifecycle_single_path_tests.erl):`-node_enrollment_crash_custody_test_/0-fun-1-/0: after_allocation` | setup: already_started |
| [178](quod-eunit-01.log:35024) | [quod_lifecycle_single_path_tests](/home/yan/src/quod/test/quod_lifecycle_single_path_tests.erl):`-node_enrollment_crash_custody_test_/0-fun-1-/0: known_refusal` | setup: already_started |
| [179](quod-eunit-01.log:35049) | [quod_lifecycle_single_path_tests](/home/yan/src/quod/test/quod_lifecycle_single_path_tests.erl):`-node_enrollment_crash_custody_test_/0-fun-1-/0: malformed_template` | setup: already_started |
| [180](quod-eunit-01.log:35074) | [quod_lifecycle_single_path_tests](/home/yan/src/quod/test/quod_lifecycle_single_path_tests.erl):`-node_enrollment_crash_custody_test_/0-fun-1-/0: admission_refusal` | setup: already_started |
| [181](quod-eunit-01.log:35099) | [quod_lifecycle_single_path_tests](/home/yan/src/quod/test/quod_lifecycle_single_path_tests.erl):`-node_enrollment_crash_custody_test_/0-fun-1-/0: auth_restart` | setup: already_started |
| [182](quod-eunit-01.log:35124) | [quod_lobby_tests](/home/yan/src/quod/test/quod_lobby_tests.erl):`-cohosted_certified_progress_test_/0-fun-3-/0` | setup: already_started |
| [183](quod-eunit-01.log:35149) | [quod_lobby_tests](/home/yan/src/quod/test/quod_lobby_tests.erl):`-class_owner_space_creation_preserves_world_test_/0-fun-10-/0` | setup: already_started |
| [184](quod-eunit-01.log:35175) | [quod_lobby_tests](/home/yan/src/quod/test/quod_lobby_tests.erl):`-inactive_physics_source_authoring_preserves_world_test_/0-fun-19-/0` | setup: already_started |
| [185](quod-eunit-01.log:35201) | [quod_lobby_tests](/home/yan/src/quod/test/quod_lobby_tests.erl):`-failed_hosting_selector_is_not_inactive_test_/0-fun-3-/0` | setup: already_started |
| [186](quod-eunit-01.log:35223) | [quod_lobby_tests](/home/yan/src/quod/test/quod_lobby_tests.erl):`-lobby_projection_recovery_test_/0-fun-19-/0` | setup: already_started |
| [187](quod-eunit-01.log:35248) | [quod_lobby_tests](/home/yan/src/quod/test/quod_lobby_tests.erl):`-first_scene_waits_for_new_lobby_route/1-fun-5-/0` | setup: already_started |
| [188](quod-eunit-01.log:35274) | [quod_lobby_tests](/home/yan/src/quod/test/quod_lobby_tests.erl):`-first_scene_waits_for_new_lobby_route/1-fun-5-/0` | setup: already_started |
| [189](quod-eunit-01.log:35300) | [quod_lobby_tests](/home/yan/src/quod/test/quod_lobby_tests.erl):`-local_subclass_inherits_eidolons_controls_and_workspace_test_/0-fun-16-/0` | setup: already_started |
| [190](quod-eunit-01.log:35326) | [quod_lobby_tests](/home/yan/src/quod/test/quod_lobby_tests.erl):`-modelling_and_material_libraries_test_/0-fun-38-/0` | setup: already_started |
| [191](quod-eunit-01.log:35352) | [quod_lobby_tests](/home/yan/src/quod/test/quod_lobby_tests.erl):`-signed_prolog_eidolon_edits_use_target_policy_test_/0-fun-16-/0` | setup: already_started |
| [192](quod-eunit-01.log:35378) | [quod_lobby_tests](/home/yan/src/quod/test/quod_lobby_tests.erl):`-complete_source_cursor_retains_current_snapshot_test_/0-fun-13-/0` | setup: already_started |
| [193](quod-eunit-01.log:35404) | [quod_lobby_tests](/home/yan/src/quod/test/quod_lobby_tests.erl):`-ontology_instances_share_selection_and_authorized_inspection_test_/0-fun-28-/0` | setup: already_started |
| [194](quod-eunit-01.log:35430) | [quod_lobby_tests](/home/yan/src/quod/test/quod_lobby_tests.erl):`-presentation_modes_and_ground_lens_targets_use_authorized_owner_reads_test_/0-fun-8-/0` | setup: already_started |
| [195](quod-eunit-01.log:35456) | [quod_lobby_tests](/home/yan/src/quod/test/quod_lobby_tests.erl):`-public_system_ontology_source_is_readable_but_not_mutable_test_/0-fun-30-/0` | setup: already_started |
| [196](quod-eunit-01.log:35482) | [quod_lobby_tests](/home/yan/src/quod/test/quod_lobby_tests.erl):`-system_ontology_editing_uses_universal_scope_identity_test_/0-fun-10-/0` | setup: already_started |
| [197](quod-eunit-01.log:35508) | [quod_lobby_tests](/home/yan/src/quod/test/quod_lobby_tests.erl):`-local_inspection_cannot_fall_back_after_root_source_denial_test_/0-fun-5-/0` | setup: already_started |
| [198](quod-eunit-01.log:35534) | [quod_lobby_tests](/home/yan/src/quod/test/quod_lobby_tests.erl):`-non_system_read_only_source_uses_the_same_recipe_test_/0-fun-5-/0` | setup: already_started |
| [199](quod-eunit-01.log:35560) | [quod_lobby_tests](/home/yan/src/quod/test/quod_lobby_tests.erl):`-scoped_routes_reuse_the_directory_and_preserve_private_admission_test_/0-fun-18-/0` | setup: already_started |
| [200](quod-eunit-01.log:35586) | [quod_lobby_tests](/home/yan/src/quod/test/quod_lobby_tests.erl):`-shared_class_edits_and_subclass_selection_use_live_definitions_test_/0-fun-14-/0` | setup: already_started |
| [201](quod-eunit-01.log:35612) | [quod_lobby_tests](/home/yan/src/quod/test/quod_lobby_tests.erl):`-large_signed_source_edit_does_not_return_inspection_scratch_test_/0-fun-5-/0` | setup: already_started |
| [202](quod-eunit-01.log:35638) | [quod_node_context_tests](/home/yan/src/quod/test/quod_node_context_tests.erl):`-permitted_recovery_helper_cannot_borrow_node_privileges_test_/0-fun-10-/0` | setup: already_started |
| [203](quod-eunit-01.log:35660) | [quod_ontology_acl_acceptance_tests](/home/yan/src/quod/test/quod_ontology_acl_acceptance_tests.erl):`run/0: module 'quod_ontology_acl_acceptance_tests'` | setup: already_started |
| [204](quod-eunit-01.log:35684) | [quod_operation_claim_tests](/home/yan/src/quod/test/quod_operation_claim_tests.erl):`direct_multi_claim_cannot_bypass_slice8_authority_gate_test/0` | later fixture/network contamination; isolated checks passed |
| [205](quod-eunit-01.log:35805) | [quod_operation_format_tests](/home/yan/src/quod/test/quod_operation_format_tests.erl):`real_qej1_with_signed_submission_is_refused_by_name_test/0` | setup: already_started |
| [206](quod-eunit-01.log:35830) | [quod_operation_receipt_tests](/home/yan/src/quod/test/quod_operation_receipt_tests.erl):`-remote_receipt_recovers_claim_bindings_test_/0-fun-1-/0: applied` | later fixture/network contamination; isolated checks passed |
| [207](quod-eunit-01.log:35856) | [quod_operation_receipt_tests](/home/yan/src/quod/test/quod_operation_receipt_tests.erl):`-remote_receipt_recovers_claim_bindings_test_/0-fun-1-/0: {rejected,conflict_retry}` | later fixture/network contamination; isolated checks passed |
| [208](quod-eunit-01.log:35882) | [quod_operation_receipt_tests](/home/yan/src/quod/test/quod_operation_receipt_tests.erl):`-remote_receipt_decode_is_a_fail_closed_boundary_test_/0-fun-1-/0: malformed` | later fixture/network contamination; isolated checks passed |
| [209](quod-eunit-01.log:35889) | [quod_operation_receipt_tests](/home/yan/src/quod/test/quod_operation_receipt_tests.erl):`-remote_receipt_decode_is_a_fail_closed_boundary_test_/0-fun-1-/0: uncorrelated` | later fixture/network contamination; isolated checks passed |
| [210](quod-eunit-01.log:35896) | [quod_operation_receipt_tests](/home/yan/src/quod/test/quod_operation_receipt_tests.erl):`-remote_receipt_decode_is_a_fail_closed_boundary_test_/0-fun-1-/0: valid_unavailable` | later fixture/network contamination; isolated checks passed |
| [211](quod-eunit-01.log:35903) | [quod_operation_receipt_tests](/home/yan/src/quod/test/quod_operation_receipt_tests.erl):`-remote_receipt_decode_is_a_fail_closed_boundary_test_/0-fun-1-/0: expired` | later fixture/network contamination; isolated checks passed |
| [212](quod-eunit-01.log:35910) | [quod_operation_receipt_tests](/home/yan/src/quod/test/quod_operation_receipt_tests.erl):`remote_receipt_checks_correlation_once_test/0` | later fixture/network contamination; isolated checks passed |
| [213](quod-eunit-01.log:35957) | [quod_outcome_endpoint_tests](/home/yan/src/quod/test/quod_outcome_endpoint_tests.erl):`-fixture_observations_end_with_owner_test_/0-fun-7-/0: normal` | later fixture/network contamination; isolated checks passed |
| [214](quod-eunit-01.log:36055) | [quod_outcome_endpoint_tests](/home/yan/src/quod/test/quod_outcome_endpoint_tests.erl):`-fixture_observations_end_with_owner_test_/0-fun-7-/0: exception` | later fixture/network contamination; isolated checks passed |
| [215](quod-eunit-01.log:36153) | [quod_outcome_endpoint_tests](/home/yan/src/quod/test/quod_outcome_endpoint_tests.erl):`operation_applied_pins_history_and_waits_for_durable_publication_test/0` | later fixture/network contamination; isolated checks passed |
| [216](quod-eunit-01.log:36251) | [quod_outcome_endpoint_tests](/home/yan/src/quod/test/quod_outcome_endpoint_tests.erl):`operation_applied_signs_historical_not_current_committee_test/0` | later fixture/network contamination; isolated checks passed |
| [217](quod-eunit-01.log:36349) | [quod_outcome_endpoint_tests](/home/yan/src/quod/test/quod_outcome_endpoint_tests.erl):`operation_collector_uses_the_real_endpoint_and_exact_result_test/0` | later fixture/network contamination; isolated checks passed |
| [218](quod-eunit-01.log:36356) | [quod_outcome_result_tests](/home/yan/src/quod/test/quod_outcome_result_tests.erl):`-lost_reply_recovers_selected_bindings_test_/0-fun-1-/0: ordinary` | setup: already_started |
| [219](quod-eunit-01.log:36378) | [quod_outcome_result_tests](/home/yan/src/quod/test/quod_outcome_result_tests.erl):`-lost_reply_recovers_selected_bindings_test_/0-fun-1-/0: foreign` | setup: already_started |
| [220](quod-eunit-01.log:36400) | [quod_outcome_result_tests](/home/yan/src/quod/test/quod_outcome_result_tests.erl):`-lost_reply_recovers_selected_bindings_test_/0-fun-1-/0: atomic` | setup: already_started |
| [221](quod-eunit-01.log:36422) | [quod_personal_agent_tests](/home/yan/src/quod/test/quod_personal_agent_tests.erl):`-signup_terms_only_test_/0-fun-9-/0` | setup: already_started |
| [222](quod-eunit-01.log:36444) | [quod_personal_agent_tests](/home/yan/src/quod/test/quod_personal_agent_tests.erl):`-class_owner_setup_form_test_/0-fun-19-/0` | setup: already_started |
| [223](quod-eunit-01.log:36466) | [quod_personal_agent_tests](/home/yan/src/quod/test/quod_personal_agent_tests.erl):`-immediate_instruction_uses_distinct_actor_test_/0-fun-0-/0` | setup: already_started |
| [224](quod-eunit-01.log:36488) | [quod_personal_agent_tests](/home/yan/src/quod/test/quod_personal_agent_tests.erl):`-foreign_and_atomic_instruction_results_test_/0-fun-2-/0: foreign` | setup: already_started |
| [225](quod-eunit-01.log:36510) | [quod_personal_agent_tests](/home/yan/src/quod/test/quod_personal_agent_tests.erl):`-foreign_and_atomic_instruction_results_test_/0-fun-2-/0: atomic` | setup: already_started |
| [226](quod-eunit-01.log:36532) | [quod_personal_agent_tests](/home/yan/src/quod/test/quod_personal_agent_tests.erl):`-interrupted_instruction_never_dispatches_test_/0-fun-2-/0: cancel` | setup: already_started |
| [227](quod-eunit-01.log:36554) | [quod_personal_agent_tests](/home/yan/src/quod/test/quod_personal_agent_tests.erl):`-interrupted_instruction_never_dispatches_test_/0-fun-2-/0: deadline` | setup: already_started |
| [228](quod-eunit-01.log:36576) | [quod_personal_agent_tests](/home/yan/src/quod/test/quod_personal_agent_tests.erl):`-interrupted_instruction_never_dispatches_test_/0-fun-2-/0: host_restart` | setup: already_started |
| [229](quod-eunit-01.log:36598) | [quod_personal_agent_tests](/home/yan/src/quod/test/quod_personal_agent_tests.erl):`-cancellation_during_target_proof_preserves_the_original_identity_test_/0-fun-6-/0` | setup: already_started |
| [230](quod-eunit-01.log:36620) | [quod_personal_agent_tests](/home/yan/src/quod/test/quod_personal_agent_tests.erl):`-retained_but_unsubmitted_instruction_is_not_replayed_test_/0-fun-7-/0` | setup: already_started |
| [231](quod-eunit-01.log:36642) | [quod_personal_agent_tests](/home/yan/src/quod/test/quod_personal_agent_tests.erl):`-unavailable_actor_does_not_dispatch_on_restart_test_/0-fun-5-/0` | setup: already_started |
| [232](quod-eunit-01.log:36664) | [quod_personal_agent_tests](/home/yan/src/quod/test/quod_personal_agent_tests.erl):`-unauthorized_and_staged_signing_are_denied_test_/0-fun-6-/0` | setup: already_started |
| [233](quod-eunit-01.log:36686) | [quod_personal_agent_tests](/home/yan/src/quod/test/quod_personal_agent_tests.erl):`-revocation_preserves_authorized_result_recovery_test_/0-fun-8-/0` | setup: already_started |
| [234](quod-eunit-01.log:36708) | [quod_personal_agent_tests](/home/yan/src/quod/test/quod_personal_agent_tests.erl):`-another_human_cannot_read_or_sign_the_instruction_test_/0-fun-3-/0` | setup: already_started |
| [235](quod-eunit-01.log:36730) | [quod_personal_agent_tests](/home/yan/src/quod/test/quod_personal_agent_tests.erl):`-human_revocation_between_signing_and_custody_refuses_dispatch_test_/0-fun-4-/0` | setup: already_started |
| [236](quod-eunit-01.log:36752) | [quod_personal_agent_tests](/home/yan/src/quod/test/quod_personal_agent_tests.erl):`-endpoint_refusal_preserves_prior_operations_test_/0-fun-11-/0: fresh` | setup: already_started |
| [237](quod-eunit-01.log:36774) | [quod_personal_agent_tests](/home/yan/src/quod/test/quod_personal_agent_tests.erl):`-endpoint_refusal_preserves_prior_operations_test_/0-fun-11-/0: retained` | setup: already_started |
| [238](quod-eunit-01.log:36796) | [quod_personal_agent_tests](/home/yan/src/quod/test/quod_personal_agent_tests.erl):`-authorization_does_not_reparse_retained_history_test_/0-fun-10-/0` | setup: already_started |
| [239](quod-eunit-01.log:36818) | [quod_physics_control_tests](/home/yan/src/quod/test/quod_physics_control_tests.erl):`-signed_binding_switch_and_release_test_/0-fun-12-/0` | setup: already_started |
| [240](quod-eunit-01.log:36840) | [quod_physics_control_tests](/home/yan/src/quod/test/quod_physics_control_tests.erl):`-binding_permission_and_geometry_guards_test_/0-fun-8-/0` | setup: already_started |
| [241](quod-eunit-01.log:36862) | [quod_physics_control_tests](/home/yan/src/quod/test/quod_physics_control_tests.erl):`-exclusive_control_and_no_body_mutation_test_/0-fun-7-/0` | setup: already_started |
| [242](quod-eunit-01.log:36884) | [quod_physics_control_tests](/home/yan/src/quod/test/quod_physics_control_tests.erl):`-ambiguous_body_ownership_test_/0-fun-2-/0` | setup: already_started |
| [243](quod-eunit-01.log:36906) | [quod_physics_control_tests](/home/yan/src/quod/test/quod_physics_control_tests.erl):`-subclass_agent_binding_test_/0-fun-2-/0` | setup: already_started |
| [244](quod-eunit-01.log:36928) | [quod_predicate_removal_tests](/home/yan/src/quod/test/quod_predicate_removal_tests.erl):`-signed_definition_removal_test_/0-fun-5-/0` | setup: already_started |
| [245](quod-eunit-01.log:36950) | [quod_predicate_removal_tests](/home/yan/src/quod/test/quod_predicate_removal_tests.erl):`-signed_origin_removal_recovery_test_/0-fun-2-/0` | setup: already_started |
| [246](quod-eunit-01.log:36972) | [quod_predicate_removal_tests](/home/yan/src/quod/test/quod_predicate_removal_tests.erl):`-signed_denial_atomic_rollback_and_conflict_test_/0-fun-2-/0` | setup: already_started |
| [247](quod-eunit-01.log:36994) | [quod_predicate_withdrawal_tests](/home/yan/src/quod/test/quod_predicate_withdrawal_tests.erl):`-signed_contents_and_selected_editor_withdraw_test_/0-fun-24-/0: module 'quod_predicate_withdrawal_tests'` | setup: already_started |
| [248](quod-eunit-01.log:37020) | [quod_prolog_scope_target_tests](/home/yan/src/quod/test/quod_prolog_scope_target_tests.erl):`signed_scope_authentication_is_verified_and_bound_test/0` | later fixture/network contamination; isolated checks passed |
| [249](quod-eunit-01.log:37046) | [quod_prolog_scope_target_tests](/home/yan/src/quod/test/quod_prolog_scope_target_tests.erl):`signed_scope_waits_when_network_identity_is_temporarily_unavailable_test/0` | later fixture/network contamination; isolated checks passed |
| [250](quod-eunit-01.log:37053) | [quod_prolog_scope_target_tests](/home/yan/src/quod/test/quod_prolog_scope_target_tests.erl):`expired_signed_scope_is_refused_before_execution_test/0` | later fixture/network contamination; isolated checks passed |
| [251](quod-eunit-01.log:37060) | [quod_proof_trace_tests](/home/yan/src/quod/test/quod_proof_trace_tests.erl):`ordinary_proof_spans_preserve_spawn_parent_and_stage_boundaries_test/0` | setup: identity_mismatch |
| [252](quod-eunit-01.log:37098) | [quod_proof_trace_tests](/home/yan/src/quod/test/quod_proof_trace_tests.erl):`failed_proof_keeps_failure_and_finishes_cleanup_without_exporting_goal_test/0` | setup: identity_mismatch |
| [253](quod-eunit-01.log:37136) | [quod_proof_trace_tests](/home/yan/src/quod/test/quod_proof_trace_tests.erl):`single_write_apply_and_publication_trace_boundaries_test/0` | setup: identity_mismatch |
| [254](quod-eunit-01.log:37174) | [quod_proof_trace_tests](/home/yan/src/quod/test/quod_proof_trace_tests.erl):`shared_batch_is_applied_once_with_two_other_request_links_test/0` | setup: identity_mismatch |
| [255](quod-eunit-01.log:37212) | [quod_proof_trace_tests](/home/yan/src/quod/test/quod_proof_trace_tests.erl):`sampled_batch_request_is_not_hidden_by_an_earlier_unsampled_request_test/0` | setup: identity_mismatch |
| [256](quod-eunit-01.log:37250) | [quod_proof_trace_tests](/home/yan/src/quod/test/quod_proof_trace_tests.erl):`uncorrelated_apply_does_not_create_request_spans_test/0` | setup: identity_mismatch |
| [257](quod-eunit-01.log:37288) | [quod_reaction_authority_tests](/home/yan/src/quod/test/quod_reaction_authority_tests.erl):`-editable_lobby_notification_cannot_borrow_node_authority_test_/0-fun-8-/0` | setup: already_started |
| [258](quod-eunit-01.log:37314) | [quod_reaction_authority_tests](/home/yan/src/quod/test/quod_reaction_authority_tests.erl):`-owned_notification_runs_only_as_the_hosted_agent_test_/0-fun-7-/0` | setup: already_started |
| [259](quod-eunit-01.log:37336) | [quod_replay_completion_tests](/home/yan/src/quod/test/quod_replay_completion_tests.erl):`-replay_completion_test_/0-fun-1-/0: member_idle` | setup: already_started |
| [260](quod-eunit-01.log:37358) | [quod_replay_completion_tests](/home/yan/src/quod/test/quod_replay_completion_tests.erl):`-replay_completion_test_/0-fun-1-/0: member_multi_window` | setup: already_started |
| [261](quod-eunit-01.log:37380) | [quod_replay_completion_tests](/home/yan/src/quod/test/quod_replay_completion_tests.erl):`-replay_completion_test_/0-fun-1-/0: observer_multi_window` | setup: already_started |
| [262](quod-eunit-01.log:37402) | [quod_replay_completion_tests](/home/yan/src/quod/test/quod_replay_completion_tests.erl):`-replay_completion_test_/0-fun-1-/0: observer_live_feed` | setup: already_started |
| [263](quod-eunit-01.log:37424) | [quod_replay_completion_tests](/home/yan/src/quod/test/quod_replay_completion_tests.erl):`-replay_completion_test_/0-fun-1-/0: initial_unconfirmed` | setup: already_started |
| [264](quod-eunit-01.log:37446) | [quod_replay_completion_tests](/home/yan/src/quod/test/quod_replay_completion_tests.erl):`-replay_completion_test_/0-fun-1-/0: projection_failure` | setup: already_started |
| [265](quod-eunit-01.log:37468) | [quod_replay_completion_tests](/home/yan/src/quod/test/quod_replay_completion_tests.erl):`-replay_completion_test_/0-fun-1-/0: network_dependency` | setup: already_started |
| [266](quod-eunit-01.log:37490) | [quod_replay_completion_tests](/home/yan/src/quod/test/quod_replay_completion_tests.erl):`-replay_completion_test_/0-fun-1-/0: stale_worker` | setup: already_started |
| [267](quod-eunit-01.log:37512) | [quod_replay_completion_tests](/home/yan/src/quod/test/quod_replay_completion_tests.erl):`-replay_completion_test_/0-fun-1-/0: stale_prolog_ack` | setup: already_started |
| [268](quod-eunit-01.log:37534) | [quod_replay_completion_tests](/home/yan/src/quod/test/quod_replay_completion_tests.erl):`-replay_completion_test_/0-fun-1-/0: prefix_not_dispatched` | setup: already_started |
| [269](quod-eunit-01.log:37556) | [quod_replay_completion_tests](/home/yan/src/quod/test/quod_replay_completion_tests.erl):`-replay_completion_test_/0-fun-1-/0: overtaken_by_live` | setup: already_started |
| [270](quod-eunit-01.log:37578) | [quod_replay_completion_tests](/home/yan/src/quod/test/quod_replay_completion_tests.erl):`-replay_completion_test_/0-fun-1-/0: successor_interval` | setup: already_started |
| [271](quod-eunit-01.log:37600) | [quod_replay_completion_tests](/home/yan/src/quod/test/quod_replay_completion_tests.erl):`-replay_completion_test_/0-fun-1-/0: empty_and_duplicate` | setup: already_started |
| [272](quod-eunit-01.log:37622) | [quod_replay_completion_tests](/home/yan/src/quod/test/quod_replay_completion_tests.erl):`-replay_completion_test_/0-fun-1-/0: ordinary_progress_no_ack_loop` | setup: already_started |
| [273](quod-eunit-01.log:37644) | [quod_replay_completion_tests](/home/yan/src/quod/test/quod_replay_completion_tests.erl):`-replay_completion_test_/0-fun-1-/0: prolog_restart` | setup: already_started |
| [274](quod-eunit-01.log:37666) | [quod_replay_completion_tests](/home/yan/src/quod/test/quod_replay_completion_tests.erl):`-replay_completion_test_/0-fun-1-/0: snapshot_reader_reaped` | setup: already_started |
| [275](quod-eunit-01.log:37688) | [quod_resource_lifecycle_tests](/home/yan/src/quod/test/quod_resource_lifecycle_tests.erl):`-unchanged_notices_and_unrelated_changes_do_no_resource_work_test_/0-fun-4-/0` | setup: already_started |
| [276](quod-eunit-01.log:37710) | [quod_resource_lifecycle_tests](/home/yan/src/quod/test/quod_resource_lifecycle_tests.erl):`-scoped_request_keeps_the_full_inventory_dependency_test_/0-fun-4-/0` | setup: already_started |
| [277](quod-eunit-01.log:37732) | [quod_resource_lifecycle_tests](/home/yan/src/quod/test/quod_resource_lifecycle_tests.erl):`-committed_height_wakes_context_dependent_selection_test_/0-fun-7-/0` | setup: already_started |
| [278](quod-eunit-01.log:37754) | [quod_resource_lifecycle_tests](/home/yan/src/quod/test/quod_resource_lifecycle_tests.erl):`-committed_height_does_not_wake_predicate_only_selection_test_/0-fun-2-/0` | setup: already_started |
| [279](quod-eunit-01.log:37776) | [quod_resource_lifecycle_tests](/home/yan/src/quod/test/quod_resource_lifecycle_tests.erl):`-queued_height_advance_supersedes_selection_before_installation_test_/0-fun-7-/0` | setup: already_started |
| [280](quod-eunit-01.log:37798) | [quod_resource_lifecycle_tests](/home/yan/src/quod/test/quod_resource_lifecycle_tests.erl):`-absent_selector_is_woken_when_defined_test_/0-fun-5-/0` | setup: already_started |
| [281](quod-eunit-01.log:37820) | [quod_resource_lifecycle_tests](/home/yan/src/quod/test/quod_resource_lifecycle_tests.erl):`-failed_selection_preserves_host_and_empty_selection_removes_it_test_/0-fun-5-/0` | setup: already_started |
| [282](quod-eunit-01.log:37842) | [quod_resource_lifecycle_tests](/home/yan/src/quod/test/quod_resource_lifecycle_tests.erl):`-negative_and_reflective_dependencies_wake_the_real_owner_test_/0-fun-5-/0: negative read` | setup: already_started |
| [283](quod-eunit-01.log:37864) | [quod_resource_lifecycle_tests](/home/yan/src/quod/test/quod_resource_lifecycle_tests.erl):`-negative_and_reflective_dependencies_wake_the_real_owner_test_/0-fun-5-/0: absent predicate` | setup: already_started |
| [284](quod-eunit-01.log:37886) | [quod_resource_lifecycle_tests](/home/yan/src/quod/test/quod_resource_lifecycle_tests.erl):`-negative_and_reflective_dependencies_wake_the_real_owner_test_/0-fun-5-/0: predicate property` | setup: already_started |
| [285](quod-eunit-01.log:37908) | [quod_resource_lifecycle_tests](/home/yan/src/quod/test/quod_resource_lifecycle_tests.erl):`-negative_and_reflective_dependencies_wake_the_real_owner_test_/0-fun-5-/0: predicate enumeration` | setup: already_started |
| [286](quod-eunit-01.log:37930) | [quod_resource_lifecycle_tests](/home/yan/src/quod/test/quod_resource_lifecycle_tests.erl):`-selection_errors_retain_the_reads_that_can_repair_them_test_/0-fun-4-/0` | setup: already_started |
| [287](quod-eunit-01.log:37952) | [quod_resource_lifecycle_tests](/home/yan/src/quod/test/quod_resource_lifecycle_tests.erl):`-unreported_selector_death_keeps_a_repair_dependency_test_/0-fun-6-/0` | setup: already_started |
| [288](quod-eunit-01.log:37974) | [quod_resource_lifecycle_tests](/home/yan/src/quod/test/quod_resource_lifecycle_tests.erl):`-unstarted_expired_selection_keeps_a_repair_dependency_test_/0-fun-6-/0` | setup: already_started |
| [289](quod-eunit-01.log:37996) | [quod_resource_lifecycle_tests](/home/yan/src/quod/test/quod_resource_lifecycle_tests.erl):`-foreign_scope_cannot_supply_node_or_root_resource_policy_test_/0-fun-5-/0` | setup: already_started |
| [290](quod-eunit-01.log:38018) | [quod_resource_lifecycle_tests](/home/yan/src/quod/test/quod_resource_lifecycle_tests.erl):`-foreign_resource_deadline_cannot_withdraw_root_limits_test_/0-fun-5-/0` | setup: already_started |
| [291](quod-eunit-01.log:38040) | [quod_resource_lifecycle_tests](/home/yan/src/quod/test/quod_resource_lifecycle_tests.erl):`-change_while_selected_result_waits_cannot_leave_obsolete_inventory_test_/0-fun-6-/0` | setup: already_started |
| [292](quod-eunit-01.log:38062) | [quod_resource_lifecycle_tests](/home/yan/src/quod/test/quod_resource_lifecycle_tests.erl):`-identity_withdrawal_completes_pending_agent_retirement_test_/0-fun-6-/0` | setup: already_started |
| [293](quod-eunit-01.log:38084) | [quod_retained_dtx_renewal_tests](/home/yan/src/quod/test/quod_retained_dtx_renewal_tests.erl):`-stale_alternative_resolve_retires_without_signing_test_/0-fun-0-/0` | later fixture/network contamination; isolated checks passed |
| [294](quod-eunit-01.log:38110) | [quod_retained_dtx_renewal_tests](/home/yan/src/quod/test/quod_retained_dtx_renewal_tests.erl):`-unrelated_resolve_commit_renews_live_retained_resolve_test_/0-fun-0-/0` | later fixture/network contamination; isolated checks passed |
| [295](quod-eunit-01.log:38136) | [quod_retained_dtx_renewal_tests](/home/yan/src/quod/test/quod_retained_dtx_renewal_tests.erl):`-exact_resolve_digests_drain_without_renewal_test_/0-fun-0-/0` | later fixture/network contamination; isolated checks passed |
| [296](quod-eunit-01.log:38162) | [quod_retained_dtx_renewal_tests](/home/yan/src/quod/test/quod_retained_dtx_renewal_tests.erl):`-stale_signature_only_invariant_has_bounded_diagnostic_test_/0-fun-0-/0` | later fixture/network contamination; isolated checks passed |
| [297](quod-eunit-01.log:38188) | [quod_retained_dtx_renewal_tests](/home/yan/src/quod/test/quod_retained_dtx_renewal_tests.erl):`-diagnostic_namespace_bounds_test_/0-fun-1-/0: namespace_255` | later fixture/network contamination; isolated checks passed |
| [298](quod-eunit-01.log:38214) | [quod_retained_dtx_renewal_tests](/home/yan/src/quod/test/quod_retained_dtx_renewal_tests.erl):`-diagnostic_namespace_bounds_test_/0-fun-1-/0: oversized_printable` | later fixture/network contamination; isolated checks passed |
| [299](quod-eunit-01.log:38240) | [quod_retained_dtx_renewal_tests](/home/yan/src/quod/test/quod_retained_dtx_renewal_tests.erl):`-diagnostic_namespace_bounds_test_/0-fun-1-/0: oversized_nonprintable` | later fixture/network contamination; isolated checks passed |
| [300](quod-eunit-01.log:38266) | [quod_retained_dtx_vote_order_tests](/home/yan/src/quod/test/quod_retained_dtx_vote_order_tests.erl):`-publication_order_test_/0-fun-1-/0: live` | later fixture/network contamination; isolated checks passed |
| [301](quod-eunit-01.log:38279) | [quod_retained_dtx_vote_order_tests](/home/yan/src/quod/test/quod_retained_dtx_vote_order_tests.erl):`-publication_order_test_/0-fun-1-/0: catchup` | later fixture/network contamination; isolated checks passed |
| [302](quod-eunit-01.log:38292) | [quod_retained_dtx_vote_order_tests](/home/yan/src/quod/test/quod_retained_dtx_vote_order_tests.erl):`-publication_order_test_/0-fun-1-/0: catchup_paused` | later fixture/network contamination; isolated checks passed |
| [303](quod-eunit-01.log:38305) | [quod_root_resource_lifecycle_tests](/home/yan/src/quod/test/quod_root_resource_lifecycle_tests.erl):`-root_policy_restores_journal_before_node_and_after_owner_restart_test_/0-fun-19-/0` | setup: already_started |
| [304](quod-eunit-01.log:38327) | [quod_root_resource_lifecycle_tests](/home/yan/src/quod/test/quod_root_resource_lifecycle_tests.erl):`-invalid_committed_limits_withdraw_and_resume_from_dependency_notices_test_/0-fun-13-/0` | setup: already_started |
| [305](quod-eunit-01.log:38349) | [quod_root_resource_lifecycle_tests](/home/yan/src/quod/test/quod_root_resource_lifecycle_tests.erl):`-interrupted_committed_limits_withdraw_until_a_real_change_test_/0-fun-12-/0` | setup: already_started |
| [306](quod-eunit-01.log:38371) | [quod_show_as_tests](/home/yan/src/quod/test/quod_show_as_tests.erl):`-inside_show_as_changes_only_what_i_see_test_/0-fun-12-/0` | setup: already_started |
| [307](quod-eunit-01.log:38393) | [quod_show_as_tests](/home/yan/src/quod/test/quod_show_as_tests.erl):`-outside_show_as_changes_only_what_i_see_test_/0-fun-9-/0` | setup: already_started |
| [308](quod-eunit-01.log:38415) | [quod_show_as_tests](/home/yan/src/quod/test/quod_show_as_tests.erl):`-infinite_space_offers_no_walls_test_/0-fun-5-/0` | setup: already_started |
| [309](quod-eunit-01.log:38437) | [quod_show_as_tests](/home/yan/src/quod/test/quod_show_as_tests.erl):`-new_eidolon_appears_by_itself_test_/0-fun-9-/0` | setup: already_started |
| [310](quod-eunit-01.log:38459) | [quod_show_as_tests](/home/yan/src/quod/test/quod_show_as_tests.erl):`-reflected_ontology_opens_without_walls_test_/0-fun-3-/0` | setup: already_started |
| [311](quod-eunit-01.log:38481) | [quod_show_as_tests](/home/yan/src/quod/test/quod_show_as_tests.erl):`-open_world_view_refreshes_on_my_choice_test_/0-fun-3-/0` | setup: already_started |
| [312](quod-eunit-01.log:38503) | [quod_source_view_tests](/home/yan/src/quod/test/quod_source_view_tests.erl):`-committed_signed_read_preserves_bindings_and_scope_restrictions_test_/0-fun-13-/0` | setup: already_started |
| [313](quod-eunit-01.log:38529) | [quod_source_view_tests](/home/yan/src/quod/test/quod_source_view_tests.erl):`class_owned_scene/0` | setup: already_started |
| [314](quod-eunit-01.log:38553) | [quod_source_view_tests](/home/yan/src/quod/test/quod_source_view_tests.erl):`-source_authorization_is_retained_and_withdrawn_test_/0-fun-11-/0` | setup: already_started |
| [315](quod-eunit-01.log:38579) | [quod_source_view_tests](/home/yan/src/quod/test/quod_source_view_tests.erl):`-long_namespace_source_view_keeps_authorization_test_/0-fun-9-/0` | setup: already_started |
| [316](quod-eunit-01.log:38605) | [quod_space_creation_tests](/home/yan/src/quod/test/quod_space_creation_tests.erl):`-signed_empty_space_results_and_recovery_test_/0-fun-10-/0: ordinary` | setup: already_started |
| [317](quod-eunit-01.log:38627) | [quod_space_creation_tests](/home/yan/src/quod/test/quod_space_creation_tests.erl):`-signed_empty_space_results_and_recovery_test_/0-fun-10-/0: foreign` | setup: already_started |
| [318](quod-eunit-01.log:38649) | [quod_space_creation_tests](/home/yan/src/quod/test/quod_space_creation_tests.erl):`-signed_empty_space_results_and_recovery_test_/0-fun-10-/0: atomic` | setup: already_started |
| [319](quod-eunit-01.log:38671) | [quod_space_creation_tests](/home/yan/src/quod/test/quod_space_creation_tests.erl):`-explicit_and_near_agent_placement_test_/0-fun-3-/0` | setup: already_started |
| [320](quod-eunit-01.log:38693) | [quod_space_creation_tests](/home/yan/src/quod/test/quod_space_creation_tests.erl):`-viewer_pose_placement_test_/0-fun-3-/0` | setup: already_started |
| [321](quod-eunit-01.log:38715) | [quod_space_creation_tests](/home/yan/src/quod/test/quod_space_creation_tests.erl):`-explicit_owner_and_class_defaults_test_/0-fun-1-/0` | setup: already_started |
| [322](quod-eunit-01.log:38737) | [quod_space_creation_tests](/home/yan/src/quod/test/quod_space_creation_tests.erl):`-invalid_dimensions_roll_back_through_signed_actor_test_/0-fun-2-/0` | setup: already_started |
| [323](quod-eunit-01.log:38759) | [quod_space_creation_tests](/home/yan/src/quod/test/quod_space_creation_tests.erl):`-authorization_and_lookup_failures_never_fall_back_test_/0-fun-7-/0` | setup: already_started |
| [324](quod-eunit-01.log:38781) | [quod_space_creation_tests](/home/yan/src/quod/test/quod_space_creation_tests.erl):`-existing_occupants_and_creation_commit_together_test_/0-fun-10-/0: local` | setup: already_started |
| [325](quod-eunit-01.log:38803) | [quod_space_creation_tests](/home/yan/src/quod/test/quod_space_creation_tests.erl):`-existing_occupants_and_creation_commit_together_test_/0-fun-10-/0: foreign` | setup: already_started |
| [326](quod-eunit-01.log:38825) | [quod_space_creation_tests](/home/yan/src/quod/test/quod_space_creation_tests.erl):`-atomic_completion_wait_includes_complete_record_test_/0-fun-6-/0` | setup: already_started |
| [327](quod-eunit-01.log:38847) | [quod_space_tests](/home/yan/src/quod/test/quod_space_tests.erl):`-class_owner_creation_and_action_chain_test_/0-fun-5-/0` | setup: already_started |
| [328](quod-eunit-01.log:38869) | [quod_space_tests](/home/yan/src/quod/test/quod_space_tests.erl):`-ordinary_travel_atomic_test_/0-fun-2-/0` | setup: already_started |
| [329](quod-eunit-01.log:38891) | [quod_space_tests](/home/yan/src/quod/test/quod_space_tests.erl):`-space_semantics_and_recovery_test_/0-fun-5-/0` | setup: already_started |
| [330](quod-eunit-01.log:38913) | [quod_space_tests](/home/yan/src/quod/test/quod_space_tests.erl):`-competing_exclusive_admissions_test_/0-fun-12-/0: gallery` | setup: already_started |
| [331](quod-eunit-01.log:38935) | [quod_space_tests](/home/yan/src/quod/test/quod_space_tests.erl):`-competing_exclusive_admissions_test_/0-fun-12-/0: catalogue` | setup: already_started |
| [332](quod-eunit-01.log:38957) | [quod_space_tests](/home/yan/src/quod/test/quod_space_tests.erl):`-distinct_owner_authorization_test_/0-fun-3-/0: gallery` | setup: already_started |
| [333](quod-eunit-01.log:38979) | [quod_space_tests](/home/yan/src/quod/test/quod_space_tests.erl):`-distinct_owner_authorization_test_/0-fun-3-/0: catalogue` | setup: already_started |
| [334](quod-eunit-01.log:39001) | [quod_space_tests](/home/yan/src/quod/test/quod_space_tests.erl):`-ordinary_placement_rollback_and_recovery_test_/0-fun-4-/0` | setup: already_started |
| [335](quod-eunit-01.log:39023) | [quod_space_tests](/home/yan/src/quod/test/quod_space_tests.erl):`-ordinary_placement_committed_permissions_test_/0-fun-2-/0` | setup: already_started |
| [336](quod-eunit-01.log:39045) | [quod_space_tests](/home/yan/src/quod/test/quod_space_tests.erl):`-ordinary_placement_policy_conflicts_test_/0-fun-4-/0: source` | setup: already_started |
| [337](quod-eunit-01.log:39067) | [quod_space_tests](/home/yan/src/quod/test/quod_space_tests.erl):`-ordinary_placement_policy_conflicts_test_/0-fun-4-/0: destination` | setup: already_started |
| [338](quod-eunit-01.log:39089) | [quod_space_tests](/home/yan/src/quod/test/quod_space_tests.erl):`-same_ontology_ordinary_placement_test_/0-fun-1-/0` | setup: already_started |
| [339](quod-eunit-01.log:39111) | [quod_space_tests](/home/yan/src/quod/test/quod_space_tests.erl):`-ordinary_placement_and_shared_display_projection_test_/0-fun-13-/0` | setup: already_started |
| [340](quod-eunit-01.log:39133) | [quod_space_tests](/home/yan/src/quod/test/quod_space_tests.erl):`-physical_placement_requires_its_body_pose_test_/0-fun-1-/0` | setup: already_started |
| [341](quod-eunit-01.log:39155) | [quod_suffix_material_tests](/home/yan/src/quod/test/quod_suffix_material_tests.erl):`-suffix_checks_finality_without_reauthenticating_content_test_/0-fun-8-/0` | later fixture/network contamination; isolated checks passed |

The cancelled fixture is the pending `quod_lifecycle_single_path_tests:setup/1`
which receives `{already_started, RouterPid}`. Its unrun cases provide no passing coverage.

Affected files:

- [quod_agent_custody_tests.erl](/home/yan/src/quod/test/quod_agent_custody_tests.erl): 4 failures.
- [quod_agent_hosting_tests.erl](/home/yan/src/quod/test/quod_agent_hosting_tests.erl): 29 failures.
- [quod_agent_reaction_tests.erl](/home/yan/src/quod/test/quod_agent_reaction_tests.erl): 1 failures.
- [quod_agent_recovery_tests.erl](/home/yan/src/quod/test/quod_agent_recovery_tests.erl): 2 failures.
- [quod_agent_vault_tests.erl](/home/yan/src/quod/test/quod_agent_vault_tests.erl): 1 failures.
- [quod_ask_tests.erl](/home/yan/src/quod/test/quod_ask_tests.erl): 15 failures.
- [quod_class_permissions_tests.erl](/home/yan/src/quod/test/quod_class_permissions_tests.erl): 2 failures.
- [quod_client_goal_ingress_tests.erl](/home/yan/src/quod/test/quod_client_goal_ingress_tests.erl): 1 failures.
- [quod_constructor_tests.erl](/home/yan/src/quod/test/quod_constructor_tests.erl): 2 failures.
- [quod_controller_tests.erl](/home/yan/src/quod/test/quod_controller_tests.erl): 2 failures.
- [quod_create_root_tests.erl](/home/yan/src/quod/test/quod_create_root_tests.erl): 1 failures.
- [quod_e2e_tests.erl](/home/yan/src/quod/test/quod_e2e_tests.erl): 3 failures.
- [quod_gui_components_tests.erl](/home/yan/src/quod/test/quod_gui_components_tests.erl): 5 failures.
- [quod_gui_examples_tests.erl](/home/yan/src/quod/test/quod_gui_examples_tests.erl): 3 failures.
- [quod_gui_hud_tests.erl](/home/yan/src/quod/test/quod_gui_hud_tests.erl): 2 failures.
- [quod_gui_menu_tests.erl](/home/yan/src/quod/test/quod_gui_menu_tests.erl): 5 failures.
- [quod_gui_operations_tests.erl](/home/yan/src/quod/test/quod_gui_operations_tests.erl): 6 failures.
- [quod_gui_question_tests.erl](/home/yan/src/quod/test/quod_gui_question_tests.erl): 5 failures.
- [quod_gui_stage1_tests.erl](/home/yan/src/quod/test/quod_gui_stage1_tests.erl): 3 failures.
- [quod_lifecycle_single_path_tests.erl](/home/yan/src/quod/test/quod_lifecycle_single_path_tests.erl): 18 failures.
- [quod_lobby_tests.erl](/home/yan/src/quod/test/quod_lobby_tests.erl): 20 failures.
- [quod_node_context_tests.erl](/home/yan/src/quod/test/quod_node_context_tests.erl): 1 failures.
- [quod_ontology_acl_acceptance_tests.erl](/home/yan/src/quod/test/quod_ontology_acl_acceptance_tests.erl): 1 failures.
- [quod_operation_claim_tests.erl](/home/yan/src/quod/test/quod_operation_claim_tests.erl): 1 failures.
- [quod_operation_format_tests.erl](/home/yan/src/quod/test/quod_operation_format_tests.erl): 1 failures.
- [quod_operation_receipt_tests.erl](/home/yan/src/quod/test/quod_operation_receipt_tests.erl): 7 failures.
- [quod_outcome_endpoint_tests.erl](/home/yan/src/quod/test/quod_outcome_endpoint_tests.erl): 5 failures.
- [quod_outcome_result_tests.erl](/home/yan/src/quod/test/quod_outcome_result_tests.erl): 3 failures.
- [quod_personal_agent_tests.erl](/home/yan/src/quod/test/quod_personal_agent_tests.erl): 18 failures.
- [quod_physics_control_tests.erl](/home/yan/src/quod/test/quod_physics_control_tests.erl): 5 failures.
- [quod_physics_tests.erl](/home/yan/src/quod/test/quod_physics_tests.erl): 53 failures.
- [quod_predicate_removal_tests.erl](/home/yan/src/quod/test/quod_predicate_removal_tests.erl): 3 failures.
- [quod_predicate_withdrawal_tests.erl](/home/yan/src/quod/test/quod_predicate_withdrawal_tests.erl): 1 failures.
- [quod_prolog_scope_target_tests.erl](/home/yan/src/quod/test/quod_prolog_scope_target_tests.erl): 3 failures.
- [quod_prolog_tests.erl](/home/yan/src/quod/test/quod_prolog_tests.erl): 14 failures.
- [quod_proof_trace_tests.erl](/home/yan/src/quod/test/quod_proof_trace_tests.erl): 6 failures.
- [quod_reaction_authority_tests.erl](/home/yan/src/quod/test/quod_reaction_authority_tests.erl): 2 failures.
- [quod_replay_completion_tests.erl](/home/yan/src/quod/test/quod_replay_completion_tests.erl): 16 failures.
- [quod_resource_lifecycle_tests.erl](/home/yan/src/quod/test/quod_resource_lifecycle_tests.erl): 18 failures.
- [quod_retained_dtx_renewal_tests.erl](/home/yan/src/quod/test/quod_retained_dtx_renewal_tests.erl): 7 failures.
- [quod_retained_dtx_vote_order_tests.erl](/home/yan/src/quod/test/quod_retained_dtx_vote_order_tests.erl): 3 failures.
- [quod_root_resource_lifecycle_tests.erl](/home/yan/src/quod/test/quod_root_resource_lifecycle_tests.erl): 3 failures.
- [quod_runtime_tests.erl](/home/yan/src/quod/test/quod_runtime_tests.erl): 3 failures.
- [quod_show_as_tests.erl](/home/yan/src/quod/test/quod_show_as_tests.erl): 6 failures.
- [quod_source_view_tests.erl](/home/yan/src/quod/test/quod_source_view_tests.erl): 4 failures.
- [quod_space_creation_tests.erl](/home/yan/src/quod/test/quod_space_creation_tests.erl): 11 failures.
- [quod_space_tests.erl](/home/yan/src/quod/test/quod_space_tests.erl): 14 failures.
- [quod_suffix_material_tests.erl](/home/yan/src/quod/test/quod_suffix_material_tests.erl): 1 failures.
- [quod_transaction_predicates_tests.erl](/home/yan/src/quod/test/quod_transaction_predicates_tests.erl): 1 failures.
