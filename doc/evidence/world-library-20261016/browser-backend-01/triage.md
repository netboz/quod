# First browser fixture

Real authentication, signed lobby initialization, active physical view, library
opening and responder setup succeeded. The shared desktop form lacked catalogue
selection rendering, although the spatial form already supported it. GuiForm
now renders that existing kind through its normal select control.

Create-world opening returned a terminal refusal. Captured reasons identify
`ontology_name(quod:gui, <<"gui-178">>)`: this lifecycle fixture founded the GUI
vocabulary under a random namespace, while authored GUI classes intentionally
refer to `quod:gui`. Existing GUI integration fixtures use the correct identity.
The lifecycle factory now shares one `quod:gui` vocabulary per isolated node,
and its normal startup test checks the actual world-creation schema. No live
source or production class-resolution rule was changed for this fixture defect.

The disposable account was provisioned by the backend fixture. Its initial
lobby setup was performed once through the shared browser initializeSpace
function, matching the existing account-completion path. Subsequent library
actions used visible controls. No browser-created world yet; no acceptance pass.

Requested fixture shutdown exited 1 because its manually started client remained
linked to the escript caller. The fixture now unlinks each owned service, as its
existing tests do, then stops them explicitly. This exit is retained as teardown
failure, not a passing browser receipt.
