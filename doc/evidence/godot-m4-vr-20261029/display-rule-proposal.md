# Bounded display prerequisite

The current read-only DRM snapshot reports connected HDMI-A-1 connector828,
`non-desktop=1`, no active encoder. The current Wayland snapshot has one lease
device for card1, zero offered connectors, and a completed device snapshot.
The user-owned custom configuration ends its monitor rules with an unmatched
output rule, `disabled=true`; its preceding named rules cover only the three
desktop displays. Installed Hyprland0.56.2 source checks the selected disabled
rule and returns before its non-desktop output lease-offer branch. This is a
concrete obstacle to the Wayland direct path. It does not explain every earlier
Xlib error or establish that granting a lease will produce headset pixels.

The investigation handoff explicitly excludes global display/session changes.
No such change has been made. The narrowly scoped proposed exception is one
temporary compositor runtime rule, without editing any configuration file:

```sh
hyprctl eval 'hl.monitor({output="HDMI-A-1", disabled=false})'
```

After the owned runtime has released its lease, restore the headset's disabled
state using only that same output:

```sh
hyprctl eval 'hl.monitor({output="HDMI-A-1", disabled=true})'
```

Before any approved attempt, retain current desktop monitor properties and
configuration hashes. Observe the lease offer through protocol notification,
then use the owned private Monado socket/state. Verify the three desktop
monitor modes/positions/scales and original file hashes after restoration.
Do not reload the compositor, alter other monitors or interrupt another app.
If the runtime rule has no effect, retain the result; it authorizes no broader
configuration change. Both commands require the requested explicit exception.
