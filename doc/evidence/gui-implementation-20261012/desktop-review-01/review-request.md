# Desktop common controls review

Review frozen tree/ and manifest.json, following AGENTS.md. Source-only; no
commands, tests or production edits. Write fable-review.md here. Review scope:
GuiForm.tsx, gui-form.css, extracted pure gui-values helpers shared with Babylon,
and the actual DOM fixture. Existing workspace model remains the only controller
interface. No live question controller, opening, recovery, app routing or headset
acceptance is claimed. The desktop rotary dial has native range, step and direct
entry alternatives; the spatial dial retains pointer operation.

Parent evidence: client 15 test files pass, TypeScript/Vite build exit0; MCP
desktop normal 1000x900 and narrow390x844 results all11 true/errors[]. The
initial opacity assertion read before React rendered; fixture now flushes the
button event. An animation-frame wait timed out in headless mode; a MessageChannel
task boundary replaces it. An initial tool expression used unsupported top-level
await. Screenshot tool failed UnknownVizError; no screenshot inspection claimed.

Spatial run at1280x1000 initially failed the unchanged expected rotary20/15
assertions, actual-10/-15 (spatial-before-01.json/log, exit1). Temporary pointer
trace showed the intended drag reached20; the supposedly outside release at
screen(5,5) still intersected the large panel and moved it to-10. The trace was
removed. Fixture now picks its outside release ray and asserts it misses the
panel, keeping all previous value assertions. spatial-after-01.json/log passes
the shared checker, exit0/browserErrors[]. No production pointer code changed.

Do not claim parent tests as reviewer runs. Check authority/draft handling,
accessibility/disabled/read-only semantics, shared helper equivalence and fixture
quality. Do not reopen prior backend or spatial architecture review.
