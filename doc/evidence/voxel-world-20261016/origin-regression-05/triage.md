224 tests passed; one failed because it expected an absolute authored position
at 1,000,001 mm to exceed a 1,000,000 mm local coordinate allowance. The accepted
origin contract deliberately makes canonical positions exact and unbounded;
the allowance now bounds native-local geometry and the installed active window.

Keep the malformed-body/local-part checks in that test, replace the obsolete
absolute refusal with an invalid-position refusal, and explicitly prove that
large canonical positions pass the shared body schema. Existing coordinate
tests refuse active sets wider than the allowance and preserve the live native
resource on an invalid reframe. The large-origin runtime test covers admitted
reframing and unchanged-repeat cost. No runtime assertion is weakened.
