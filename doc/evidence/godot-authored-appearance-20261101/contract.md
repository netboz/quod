# Authored GUI appearance — checkpoint236

The current contract is the existing anchored GUI component tree and its
recipe/vocabulary admission. The historical `gui_view/7` proposal is not a
second runtime protocol. Appearance extends the container property vocabulary;
it does not change the signed request, operation, subject or draft owner.

`property(appearance, inherit)` means the enclosing appearance (or the adapter's
offline defaults). `property(appearance, appearance(1, Tokens))` supplies unique
named renderer-neutral tokens on that container occurrence. Colours are
`rgb(R,G,B)` with integer channels 0–255. `panel_opacity` is integer permille
0–1000. `spacing`, `padding` and `corner_radius` are nonnegative integer logical
units; the native adapter must explicitly refuse an extent it cannot represent.
Colour roles are `panel`, `field`, `text`, `accent`, `edge`, `error` and `success`.
Unspecified tokens inherit. Unknown versions, roles, duplicate roles, malformed
values or ambiguous attribute declarations are refused by the existing schema
owner. No CSS, executable property or renderer handle is accepted.

Only the container panel may use alpha. Text, fields, controls, focus indicators,
status and the adjacent keyboard remain opaque. Desktop and local Opaque override
panel alpha; local text size and native minimum targets retain precedence. These
are presentation defaults, not physical readability or comfort certification.

The semantic schema digest omits only the appearance property recursively.
Other properties, exact bindings and continuation preconditions remain covered.
The native consumers compare that same semantic tree and update existing native
themes in place. They retain controls, local strings, selection/caret and original
work. An appearance cannot grant interaction. Geometry changes cancel the existing
capture before layout changes; unchanged declarations do not repaint or acquire
resources. A denied/withdrawn view still retires through the existing consumer.

Signed refresh revokes input immediately. The same representation consumer can
retain hidden graph/scene resources until its replacement is accepted. Stored-source
text reuse additionally requires the same exact subject dependency height from
the accepted projection, the same semantic workspace, session and completed
source read. A changed dependency still rereads the committed source; denial,
selection replacement and disposal clear the retained presentation. The native
editor keeps its own selection while focus and the keyboard are revoked.

Computed inspection lenses have different freshness requirements: an authored
recipe may change its computation or read live runtime information without
changing the selected target's history. They re-evaluate through the existing
signed cursor on each accepted refresh, retain the same native editor, and assign
text only when the accepted result changes. A target-height-only result cache is
not valid for these computations. Required cursor reads are measured separately
from history/rebuild/disk-write/sync work and native resource replacement.

The existing browser parser accepts `inherit` without changing its ordinary form,
question or operation semantics. Its Babylon/React adapters do not implement
authored themes in this checkpoint: non-inherit appearance is an explicit
unsupported-renderer error. No tokens are silently dropped, and no browser
authored-theme completion is claimed. Godot is the qualified authored consumer.

Evidence labels remain separate: baseline01 is a refused fixture transaction
before appearance; baseline02 is an unused source-only build. Baseline03 uses
explicit owned source clauses, consistent with the existing source compiler,
instead of asking the construction hook to create fixed instance identities.
