# Hardware fixture correction

Previous run08 failed and cleaned up (runtime exit0, display restoration0,
desktop geometry preserved). No hardware acceptance. Run07 was interrupted;
its runtime log also shows a simulated device, invalidating its readiness claim.

Vite's cached dependency had masked an undeclared UI Babylon import. Moved the
hardware fixture module into client/test, where Babylon is declared, following
the existing spatial fixture layout. Updated its HTML and checklist link.
No production behavior changed. Native launcher now refuses readiness unless
the runtime reports the actual HTC Vive. This tree is frozen in source.json.
