Accounting for that emphasis changes a few of my Part 2 recommendations and adds requirements prose. Nothing in Part 1 changes. This is an addendum to the review above; the mockup remains a flat prototype, not headset evidence.

**What changes in my recommendations.**

- **Opacity.** I withdraw the suggested 850-permille floor as a default. Make the token range 700 to 1000 permille with 780 as the prototype default, user-adjustable, and keep the approximate contrast concern as a *measurement task* rather than a floor: the bright-world legibility of supporting text at 780 is exactly what headset testing must settle. Keep opaque mode as a one-touch preference.
- **Supporting text.** With a lower panel opacity, drop the 14-unit supporting role on translucent regions entirely. Supporting text is 16 units minimum everywhere; the muted colour is allowed only over the opaque well or the opaque status strip.
- **World visibility is a feature, not a side effect.** The panel is translucent so the user keeps situational awareness: objects, other participants and motion behind it. That argues for keeping the panel narrow and never stacking two translucent surfaces. The rail and the working panel should be side by side with a gap, never overlapping, and the keyboard plane must be opaque since it sits over the panel.
- **Opaque foreground stays mandatory.** Text, input wells, thumbs, pointers, check marks and the status strip are 1000 permille. Only the panel background and the rail background carry the opacity token.

**Requirements prose, ready to add under "VR ergonomics".** All numbers are prototype tokens for comparison on the intended headsets.

> The GUI is designed for VR first; desktop is the parity adapter. Panels are translucent so the world stays visible behind them. Only panel and rail backgrounds carry the opacity token, with a prototype default of 780 permille and a user-adjustable range of 700 to 1000. Text, input wells, control marks, the keyboard and the status strip are opaque. Translucent surfaces never overlap each other.
>
> Placement: the working panel is summoned once to a world-stable pose, centred slightly below eye line at a comfortable forward distance, and does not follow the head. Only the attention pill is body-anchored. The user can move, recenter and hide the panel with single ray actions. Object-associated forms open beside their object facing the user and can be brought into the personal workspace. Placement tokens are summon distance, panel width as a visual angle and vertical offset; the current 1.8 × 1.7 metre plane at 1.6 metres is an implementation fact to replace by measured tokens.
>
> Hit targets: every interactive element has a minimum target expressed as a visual angle token, with a prototype texture mapping of 48 texture units and 56 for the primary action, and a minimum gap token between adjacent targets. The destructive action is separated from the primary by at least one target width and confirmed by a second press. Sliders and knobs accept a linear ray drag; no interaction requires wrist rotation, two hands or depth precision. Targets enlarge while hovered by the ray so that aim is forgiving at the far edge of the panel.
>
> Legibility: text roles are expressed as angular sizes per device profile. Supporting text is never smaller than body text on translucent regions. Legibility of every text role is measured against a bright scene, a dark scene and a moving background at the prototype opacity before any token is adopted.
>
> Validation: the flat mockup demonstrates composition, states and opacity behaviour only. Headset sessions establish apparent size, depth comfort, legibility at the chosen opacity, mis-selection rate and arm and neck comfort for seated and standing users.

**Mockup alignment items for the parent.** Set the plan token table to 780 permille and the word "opacity" throughout. Keep the adjustable slider but label it "Panel opacity" with the percentage shown as opacity. Draw at least one opaque world object partly behind the panel so the translucency reads as world visibility rather than as a lighter colour. Add a "Larger text" and "Opaque panels" preference pair beside the opacity slider, since those are the two accessibility escapes the translucent default depends on.
