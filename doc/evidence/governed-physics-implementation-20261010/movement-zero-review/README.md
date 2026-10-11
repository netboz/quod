# Integer zero in signed movement

The actual normal desktop sent `drive(vector(0,-0.0,2000),vector(0,0,0))`
when the backward key was held. Prolog correctly refused the float where the
physical control contract requires integer millimetres. The shared client
quantizer now normalizes integer zero for drive, push and teleport. Generic
Prolog number formatting still preserves negative floating zero.

Fable approved the plan and implementation. Original failing regressions,
true child exits, focused passing tests, all15 client test files and an
actual emitted-bundle probe are retained. The bundle probe verifies keyboard
conversion and signed submillimetre truncation while generic `number(-0)`
remains a float. Neither these tests nor review substitute for the pending
release and real signed desktop acceptance.

The plan reviewer read a test outside its original frozen packet; the later
implementation review used a complete fixed packet and its receipt records
unchanged inputs. The archive preserves both scopes and all diagnostics.
