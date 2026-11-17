# Kando pie menu: reference for Quod menus (2026-11-05)

Kando (https://kando.menu, https://github.com/kando-menu/kando) is a cross-platform
desktop pie menu for mouse, stylus, touch and controller. Yan asked to take its
ideas for Quod's instance and space menus, especially recursion.

Screenshots: `menu-dark.png` (one level), `accordion-slide1.png` (a submenu open).

## Recursive menus
- **Submenu placement:** the submenu opens where its item sat in the parent, so the menu moves with the user's motion. See `accordion-slide1.png`: the "Kando on Discord" submenu.
- **Parent and back:** the parent shrinks to a small node joined by a line, in the opposite direction. That direction is "back"; moving there returns to the parent.
- **The centre:** it names the item currently under the pointer. A line joins the centre to the pointer.
- **Selection:** by direction. The whole wedge is the target, so no precise aim is needed.

## Interaction modes
These are progressive; Kando teaches them in this order.
- **Point and click:** click anywhere in an item's wedge.
- **Marking mode:** hold and drag through the items. A submenu opens when you stop moving or turn sharply. Zig-zag strokes work better than curves. The user learns the path to a nested item and can draw it without looking.
- **Turbo mode:** while the opening key or button is held, movement browses and release selects.
- **Hover mode:** dwell on an item to select it. This is optional and can cause accidental selection.

## Principles
- The menu reacts to the user's motion; speed comes from memorized paths.
- Context-aware: different menus open depending on what is under the pointer. In Quod: the instance, or the containing space when nothing is hit.
- Themes, icon sets and sounds are part of the menu.

## Fit for VR
- Use the controller ray direction (or thumbstick or touchpad direction) instead of a mouse drag.
- Turbo mode maps naturally to holding the menu button, aiming and releasing.
