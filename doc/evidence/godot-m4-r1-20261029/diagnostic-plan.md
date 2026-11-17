# Bounded shutdown diagnosis

This records hypotheses and observations for QUO-65 M4-R1, not a second status
authority. QUO-65 remains in-review80 and parent QUO-60 remains67.

The existing close chain is Main.CloseApplication: cancel action/backup; retire
session (world/view/physics/question/form/source/model-load consumers); await
ViewsDisposed/activeAction/backupWork/XR loads; retire model templates and await
their loads; request native XR stopping under the existing absolute5s deadline;
release identity/writer lease; SceneTree.Quit; Godot calls tree exits and retires
engine/native resources. Async methods capture the Godot synchronization context
unless their existing implementation states otherwise. No blocking Task.Wait,
Result or GetAwaiter().GetResult was found in the clean production client.

Concrete hypotheses:

- H1: owned managed retirement never completes. Temporary markers identify the
  last phase and existing task IDs/statuses; individual view completion markers
  distinguish view lifetime cancellation from other waits.
- H2: a completion is ready but its main-thread continuation cannot execute,
  or an unobserved close fault prevents Quit. Thread/context markers and owned
  thread stacks distinguish this from pending I/O. Existing qualification failure
  handling remains unchanged.
- H3: CloseApplication reaches Quit and tree exit, then engine/resource/native
  driver destruction blocks. Engine verbose teardown plus argument-free thread
  stacks identify the owner. OpenXR initialization is absent in these desktop
  runs, so native OpenXR acceptance is a separate dependency.

First diagnostic source is candidate09 plus a separately preserved temporary
Main/SignedView observation patch. No domain/server/dependency change. Remove
temporary observation from live production after retaining its exact bytes.

Run at most three separately labelled physics/normal-close disposable campaigns
on the diagnostic source, stopping earlier on a captured causal stall. One local
normal-close/backup case may discriminate networked from offline retirement.
Do not turn passing repetitions into a fix claim or run an indefinite soak.
New causal evidence may justify a specific deterministic reproduction/correction
and its affected journeys; otherwise hand off the exact unresolved boundary.

Each driver retains its complete source before execution. Raw output/native
diagnostics stay in a0700 private task directory; public copies are sanitized.
After the existing completion marker, arm one stack capture at20s if the child
is still alive. This is a diagnostic deadline, not readiness polling. The
original60s inactivity watchdog stays unchanged and still fails/kills the child.
The15s stack capture bound must finish before that watchdog; never extend it.
Only this driver's exact owned PID is attachable, using parent-scoped ptrace
permission. GDB disables frame arguments/entry values, captures bounded stacks,
detaches; no memory dump, environment or command-line inspection is permitted.
No production sleeps, retries, forced quit, fire-and-forget retirement or new
exit path is introduced.

All historical failures and private original operations remain intact. A
passing normal-close backup cannot explain the failed normal-close physics
campaign. A captured new cause must be assessed against both historical cases;
where no historical stack exists, report that attribution limit explicitly.

After two observed physics closes passed, the third planned attempt runs the
exact historical final04 export with its original engine flags. This separates
a possible observation/verbosity timing effect without broadening into a soak.
The retained per-campaign driver versions distinguish the command change.
