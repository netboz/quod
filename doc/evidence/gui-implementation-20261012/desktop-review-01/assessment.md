# Independent desktop review disposition

The parent checked Fable's findings against the model, helpers, DOM fixture and
actual browser results. The desktop adapter uses the existing workspace model;
it does not own drafts, submissions or outcome recovery. It is not yet wired to
a live question workspace.

D1 and D2 are accepted and fixed: read-only text/numeric inputs remain focusable
using native readOnly, all read-only fields have a description, selects retain
their native disabled alternative, and unsupported editor kinds use plain text.
D5's opacity label issue is fixed. A generic error boundary is deferred to the
workspace integration; decoded common forms already reject malformed ranges.

D3 gained off-grid rotary, read-only, inherited-disabled and help checks plus
unhandledrejection capture. Real native range keyboard stepping has not been
tested by the current MCP fixture and is not claimed despite the review's
general "D3 fixed" label. D4 is a requirement on the future question controller,
not permission to move domain validation or submission into the renderer.

The follow-up review raises no new defect. Exact source is frozen in tree/ plus
followup-01/tree/. Client gate 02 passes 15 test files, true exit0; TypeScript/Vite
build 02 exits0 to /tmp. Normal 1000x900 and narrow 390x844 MCP fixtures each pass
16 assertions and report no browser errors; desktop-after-02.log records the
checker exit0. The corresponding screenshots were inspected for layout and
readability, not headset comfort. Controls stay opaque as the panel changes.

The shared spatial helper extraction passes the existing browser checker after
the corrected outside-release fixture. The initial exit1 and complete result
remain in spatial-before-01.*; all previous expected values are unchanged.
The pointer trace showed20 at the intended drag point, then -10 when the alleged
outside release still intersected the panel. No production pointer change was
needed. The fixture now proves its release ray misses the mesh.

Earlier tool/fixture issues remain described in review-request.md. The screenshot
tool initially rejected an unregistered fixture file type; using the real mockup
document as tool context with the explicit browser session succeeded. Browser
sessions later expired, so fresh sessions were opened for the follow-up; no
failed run was silently represented as passing.

Build 01 wrote generated explorer output to the default directory. Those generated
files were identified from its exact log, archived under
/tmp/quod-gui-build-output-01.tar.gz and restored to the tracked baseline. Build02
uses a temporary output directory. No commit or server deployment occurred.
