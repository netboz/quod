# Lobby capability check for the world-entry plan

The existing lobby's founded `quod_agent_predicates` capability is sufficient for the tested terrain GUI lifecycle. A separate ontology or a new founded predicate module is not justified by that lifecycle.

The [isolated fixture](quod_gui_minimal_profile_review.erl) copies the existing terrain GUI test and changes only its Erlang module name and the responder's founded module list: `[quod_agent_predicates, quod_agent_work_predicates]` becomes `[quod_agent_predicates]`. The [runner](run.py) uses the compiled production and helper modules from the validated `clean-gates-04` snapshot. It does not edit production code or the frozen source tree.

The signed open, submit and automatic hosted completion sequence passed, including creation owned by the human, viewing-distance change, digging, rejection of a generation draft made stale by another dig, HUD consumption and unchanged-read I/O checks. The browser acknowledgement remains the existing fixture; this is not live browser acceptance. The child exited **0** in **15.65 seconds**; see [full log](run.log) and [receipt](receipt.json).

The code supports the result: [the additional work module](../../../../src/predicates/quod_agent_work_predicates.erl) registers only `continue_agent_work/2`. The ordinary [GUI completion](../../../../priv/ontologies/gui_question.pl) uses the existing hosted request lifecycle and does not call that predicate. Same-scope form/responder composition is separately exercised by the existing [remote GUI test](../../../../test/quod_ask_SUITE.erl:803); this experiment did not rerun that test.

The complete lobby composition still needs implementation acceptance with the real human/lobby scope pair, exact application policies and several physical worlds. The result removes a claimed capability blocker; it does not authorize live source installation or prove the future world-entry UI.

Implementation follow-up: correct the GUI documentation's overly broad module requirement and exercise the actual required capability set in the existing production-seam fixture. Preserve unrelated work-continuation capability documentation and users.
