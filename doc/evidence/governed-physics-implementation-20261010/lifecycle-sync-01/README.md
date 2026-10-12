# Lifecycle assertion synchronization

Gate04 exposed two test races. The ordinary-view test now deliberately suspends its physics process, verifies the pending retirement, resumes it and joins the runtime DOWN handler before asserting removal. The space test observes runtime runner completion before checking its live state; its Prolog replay edge also matches the exact engine incarnation. Waits are driven by message processing with bounded deadlines, without sleeps or production changes.

Campaign01 omitted the compiled helper directory from the standalone code path and stopped on six undef errors before starting fixtures. Campaign02 corrects that harness path and passes all six tests: both ordinary world identities, numeric validation, space semantics/recovery, exclusive concurrent admissions and distinct owner authorization. Full logs, source hashes, commands and STOP are retained. The separate full release campaign remains required.
