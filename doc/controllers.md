# Controllers

How a hand controller is described, how its buttons are bound to actions, and
where a user's own choices are kept. Written on 2026-11-17 from the controller
design of 2026-10-26 (Yan asked for its implementation that day) and checked
against [quod_controllers.pl](../priv/ontologies/quod_controllers.pl),
[quod_user.pl](../priv/ontologies/quod_user.pl) and the Godot client's
[Controllers.cs](../client/godot/Core/Controllers.cs).

Not checked yet with the two physical Vive wands: button exposure, model
alignment, tracking and comfort. The sections "When things change" and "One
gesture, one consumer" are the rules of the design; each one has not been
verified in the Godot client.

## Four things kept apart

| Thing | What it is |
| --- | --- |
| A physical controller | A real wand in the current headset session. Two wands are two live sources of the same class. No list of connected hardware is stored. |
| Its picture | The Eidolon of its class, drawn at its grip. A picture proves nothing about tracking, reach or contact. |
| A role | What a hand is used for: `navigation` or `menu`. Left and right are observations, not classes. |
| An agent's own hand or tool | An entity of a world, governed by that world. A wand is never bound to it automatically. |

A controller does not become the user's agent, an agent's hand, or a physical
body.

## Descriptions

`quod:controllers` holds the classes `device`, `xr_controller` and
`htc_vive_controller`. A description names a controller's parts; parts are not
entities of their own:

| Part | Type | Gives |
| --- | --- | --- |
| `trigger` | trigger | press, value |
| `grip` | squeeze | press |
| `pad` | touchpad | press, touch, two axes |

One Vive description serves both wands. Another device needs its own authored
description; a client never guesses a substitute part.

## Bindings

A binding joins a role, a part and a gesture to one action. The defaults:

| Action | Role | Gesture | Goes to |
| --- | --- | --- | --- |
| select | any hand | trigger, press and release | the client: pointing and selecting |
| menu | menu hand | pad held, direction, release | the client: the [pie](main-screen.md#the-pie) |
| drive | navigation hand | pad axes while the grip is held | movement control |
| snap | navigation hand | pad pressed left or right, grip not held | movement control |
| teleport | navigation hand | pad pressed forward, grip not held | movement control |

By default the left hand is the navigation hand and the right hand the menu
hand.

`controller_configuration/2` checks a whole set of choices before it is used:
the roles, each binding's shape, and that no two bindings on one hand claim the
same gesture. A selection binding must remain. A binding only chooses a
gesture: it grants no ability. What a movement may do is decided by the world's
own rules ([movement](physics-native.md#played-agent-movement)).

The three movement bindings are why folding this ontology into `quod:gui` is
parked until movement is engineered (Yan, 2026-11-17).

## A user's own choices

A user's choices are private. They are one attribute, `controller_preferences`,
on the human in the user's own ontology: the two roles, the set of defaults,
and overrides that disable or replace a default binding. The shared
descriptions are public; the choices are not.

- `controller_preferences_view/2` is the signed read. It gives the revision, a
  digest and the checked mapping. It lists no connected device.
- **Controller settings**, under [Me](main-screen.md#the-strip), is the form.
  Saving compares the revision and the digest the user saw, so a save against
  an older description is refused. Reset returns to the shared defaults.
- When the shared description changes, the stored choices are not rewritten.
  An override that no longer fits is shown as invalid; it is never replaced
  silently by a default.

## When things change

- A controller starts disarmed: its buttons must be seen released before a new
  gesture counts.
- Lost tracking cancels that hand's gesture without choosing anything. When
  tracking returns, a button still held is not a new press.
- A disconnected controller loses its gesture and its ray. Nothing is replayed
  when it comes back.
- A hand whose side is unknown never receives the menu role by itself.
- A role must resolve to exactly one live controller. If it is ambiguous, it
  stays disabled and says why.
- A missing part disables only the bindings that need it.
- A changed mapping cancels the gestures in progress and installs whole.

## One gesture, one consumer

1. A cancel comes first, and a cancel never clicks or chooses.
2. A drag or a form control keeps its hand until release. An open panel stops
   movement.
3. An open pie belongs to the hand that opened it. Other hands cannot steer or
   release it. A pie stops movement on every hand.
4. With nothing open: the pad with the grip held drives; without it, the left,
   right and forward sectors are snap and teleport. One press gives at most
   one request.
5. Selecting is available on either hand when nothing above has taken it.
