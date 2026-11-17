# Main screen and pies

What the Godot client shows after sign-in, on the desktop and in the headset.
Decided by Yan on 2026-11-05, with his later rulings of 2026-11-06, 12, 13 and
14. This page gathers them from the plans they were written in; it is the
reference now. What a space's own Eidolons are is in
[Governed spaces](spaces.md); what an Eidolon is, in
[Eidolons](gui-plan.md#eidolons).

## The screen

The screen shows the world and nothing else, except:

- top left, the logo and the name of the space I am in;
- at the bottom, the strip, until it is removed (see [The strip](#the-strip)).

There is no sidebar, no header, no tools panel.

A form or a view opens as a panel over the world. One panel at a time: opening
another replaces it. A form that was validated or cancelled closes. A press
outside an open form closes and cancels it, on the desktop too. A form that was
sent and whose result is not known stays, and cannot be closed.

## Pointing

The ray in the headset, the cursor on the desktop, chooses a thing before any
press.

**The target.** The thing pointed at. When nothing is pointed at, the space my
agent is in. When my agent is in no space, my agent itself.

A pointed thing lights gold; its Eidolon carries that look, and the look it has
once selected, so the client switches them with no read. Pointing at nothing
shows nothing: no text names the space.

The name of a thing is written above it. A name stays fixed in the world and
faces the thing's front; it never turns with the head. It is readable from both
sides.

## The pie

A pie belongs to one target. It opens with the menu action: the pad press in
the headset; on the desktop the right button, or the Menu key.

- **Wedges keep their places.** Slot 1 is the top wedge, then clockwise. A
  level has eight wedges unless its author says otherwise. When a level holds
  more entries than wedges, the pinned ones keep their place and the rest go
  under **More**. Nothing is dropped.
- **A wedge is one choice**: one Eidolon of one exact thing, which is an action
  or a view, or a pie inside the pie. An inner pie opens where its wedge was;
  the wedge opposite goes back.
- **Wedges show a picture**, or the caption's initials in a disc when the thing
  has none. The middle of the pie names the wedge pointed at.
- **A wedge that cannot be used is dimmed, never hidden.** The middle says why.
- **Choosing is by direction.** With the pad held: the thumb on the pad or the
  ray on the pie lights a wedge, and releasing the pad chooses it. The trigger
  on a wedge, or a click, chooses it too. Resting on a wedge never chooses it.
- **The pie reaches as far as its ring.** The middle, and anything past the
  edge, is no wedge; releasing or clicking there closes the pie.
- **An action without fields runs when chosen.** A wedge may ask for a second
  press; the middle then reads "Press again". A form with fields opens its
  panel.
- **A pie never points at nothing.** When its target goes away, the pie closes
  and the strip says "That thing is no longer here."

On the desktop, the arrow keys and the digits choose a wedge, Backspace goes
back and Escape closes. The middle button turns the view. F9 enters and leaves
the headset.

A pie shows what its target offers; it grants nothing. Choosing a wedge runs
the same checks as sending the goal directly.

### The pie of a space

| Slot | Wedge | What it does |
| --- | --- | --- |
| 1, top | **Create here** | The space class's creation forms. |
| 2 | **Show as** | The Eidolons for what I am looking at; see [Governed spaces](spaces.md#same-agent-travel). |
| 3 | **Inspect** | Source, inspections and the workbench of the ontology that stores the space. |
| 5, bottom | **Leave space** | Asks a second press. |
| free | **Go to** | The spaces standing in this one; choosing one enters it. |

The other actions the space offers take the free wedges.

### The pie of my agent

Its title is "You", or "You are nowhere yet" when my agent is in no space.

| Slot | Wedge |
| --- | --- |
| 1 | **Enter a known space** |
| 3 | **Create a space** |
| 5 | **Your choices** |

### The pie of any other thing

A class that declares no pie gets the shared one: the thing's actions first,
then **Show as** with its outside Eidolons and its edition, then **Inspect**
with its source and inspections.

## The strip

**The strip will be removed** (Yan, 2026-11-17). What becomes of its commands,
and of the commands others put on a HUD, is not decided. Until then it works
as written here.

Each human has one HUD, stored in their own ontology. The strip shows its
commands. A command is a wedge: pressing it does what the same wedge does in a
pie, and a command may open a pie.

In order:

1. **Your attention**: the number of questions waiting for me. It shows 0; it
   does not go away.
2. **Me**: my own pie.
3. The commands of the space I am in, while I am in it.
4. The commands others put there and I accepted.
5. **This device**, last: text size, panel opacity, the headset, where the
   panel stands. It is the only command the client writes itself.

The strip shows twelve commands; the rest go under **More**. Twelve is written
in the human's ontology, not in the client.

The last status is one plain sentence above the strip.

**Who may put a command on my strip.** Myself, my agent, and the owner of the
space my agent is in: directly. Anyone else leaves an offer, and only an agent
I already allow to ask me questions may leave one. The offer waits in my
ontology; I accept or decline it with my own action, **Offered commands**.
Waiting offers are not counted and not limited. Whoever put a command or an
offer may take it back; I may remove any command.

A command whose source cannot be read stays in its place, dimmed, as
"Unavailable". It is never dropped silently, because I placed it.

## Where things stand in the headset

These rules hold for every surface: panel, form, pie, strip, keyboard, name
(Yan, 2026-11-14).

- between 1.25 m and 5 m away;
- between eye level and 35° below it, never more than 10° above;
- facing the eye;
- fixed in the world, never following the head;
- text at least 0.6° tall, targets at least 1°.

| Surface | Where |
| --- | --- |
| Panel | In front of the head at the moment it opens, its middle 9° below eye level. "Nearer" stops at 1.25 m. |
| Form beside a thing | The panel's distance and height, facing the eye, set to the thing's side. |
| Pie | 1.5 m away, at least 15° below eye level, for a pointed thing as for the space. |
| Strip | 35° below eye level. It stays in the room and takes a new place in one glide of 0.3 s once the head has turned 35° or moved 0.5 m. |
| Keyboard | Under the panel. The strip hides while it is up. |

On the desktop a pie opens on the cursor and a panel docks to the side of the
window farther from the target.

## In the code

- A pie is an Eidolon whose purpose is `menu`. `menu_tree/2` in
  [quod_gui.pl](../priv/ontologies/quod_gui.pl) builds every pie: slots, the
  back wedge, **More**. The eight wedges are
  `gui_attribute(menu, wedges, positive_integer, default(8))`.
- `client_menu/2` is the one signed read for a pie. `gui_menu_source/2` gives a
  thing's captions and whether each choice is available.
- The space's pie is `space_menu` in
  [quod_space.pl](../priv/ontologies/quod_space.pl); the agent's is
  `personal_menu` in [quod_user.pl](../priv/ontologies/quod_user.pl); the
  shared one is `default_menu` in `quod_gui.pl`.
- The HUD is the class `hud` of `quod:gui`. `hud_commands/1` is its signed
  read; `hud_allowance/2` holds the twelve. `hud_contribute/2`, `hud_offer/2`,
  `hud_answer_offer/3`, `hud_withdraw/2` and `hud_withdraw_offer/2` are the
  ways in and out.
- The pointed and selected looks travel with a mark
  ([gui_scene.pl](../priv/ontologies/gui_scene.pl)).
- The client: `PieMenu.cs`, `HudBar.cs`, `Core/Menus.cs`. The headset's
  distances and angles are `DeviceProfile` in `Core/Menus.cs`; no surface keeps
  its own.
