# VR and desktop-3D UI ergonomics — research digest (2026-11-05)

Web research for the Quod Godot client main screen. Microsoft Mixed Reality and
Apple visionOS give hard numbers; Meta's current pages are mostly qualitative.
(2nd) = secondary or community source, not the vendor's own page.

## Panel placement
1. **Distance:** comfort zone 1.25–5 m; keep content at 1 m or more; fade at 40 cm, clip at 30 cm. Depth motion and near/far focus switching strain the eyes. https://learn.microsoft.com/en-us/windows/mixed-reality/design/comfort
2. **Angles:** content 0–35° below the horizon, resting gaze 10–20° below. Avoid more than 10° up, more than 60° down, or more than 45° of neck turn. (same URL)
3. **Text size:** minimum 0.35–0.4° (about 12–14 mm at 2 m); comfortable 0.6–0.75° (about 21–26 mm at 2 m). https://learn.microsoft.com/en-us/windows/mixed-reality/design/typography — Meta's floor is 14 px with 4.5:1 contrast: https://developers.meta.com/horizon/design/pwa/
4. **Target size:** ray targets at least 1° (3.5 cm at 2 m). https://learn.microsoft.com/en-us/windows/mixed-reality/design/interactable-object — visionOS: button centres at least 60 pt apart. https://developer.apple.com/design/human-interface-guidelines/spatial-layout
5. **Locking:** never head-lock content. Prefer world-locked; use body-locked (turns only past a threshold) for a HUD. https://learn.microsoft.com/en-us/windows/mixed-reality/design/billboarding-and-tag-along
6. **Panel count:** use few panels; no panel so large the user must turn to see it. https://developers.meta.com/horizon/design/comfort/

## Menus
7. **Pie menus:** about 15% faster than lists with fewer errors; good for 3–12 items (Callahan et al., CHI 1988). Validated in immersive VR (Gebhardt et al., TVCG 2013).
8. **Context menus:** secondary actions only, placed near the target, showing only that target's actions. Every action also needs a visible path. https://www.nngroup.com/articles/contextual-menus-guidelines/
9. **Hand and wrist menus:** about 3 quick actions; they become world-locked when the hand drops; give them a handle and a close button. https://learn.microsoft.com/en-us/windows/mixed-reality/design/hand-menu
10. **Reserved buttons:** SteamVR reserves the system button (2nd); Index B is commonly the context button (2nd). Meta expects the left menu button to open the app menu. https://developer.oculus.com/resources/vrc-quest-input-1

## Pointing and selection
11. **Trigger selects.** Give hover, pressed and idle feedback (visual, sound, haptic) and a cursor at the hit point. Hover fades in over about 0.3 s; press responds in about 0.08 s. Cast the ray from a steady origin and filter jitter. Snap to 3D objects, not to 2D UI. https://developers.meta.com/horizon/design/raycasting_bp/
12. **Godot:** XR Tools pointer plus Viewport2Din3D behaves like a mouse on 2D UI; start from an empty OpenXR action map. https://godotvr.github.io/godot-xr-tools/docs/pointer

## Comfort
13. **Motion:** prefer teleport and snap turn (30, 45 or 90° steps), a vignette during artificial motion, and a steady 60+ fps. https://developers.meta.com/horizon/design/locomotion-comfort-usability/
14. **Arms:** indirect (ray) input for long tasks; support seated use.

## Text input
15. **Avoid forms in VR:** use pickers and presets, and voice for free text; keep long editing on desktop. Ray plus virtual keyboard is the best selection keyboard (Speicher et al., CHI 2018).

## Recommendations for Quod
1. **One rule for both kinds of menu:** the ray or cursor picks the target (the hit instance, or the containing space when nothing is hit). The menu button (Vive menu, Index B) or right-click / Menu key opens that target's menu. Trigger or left-click only selects. Never bind the system button.
2. **Show the target before the press:** when the ray hits nothing, give the ray tip a distinct "space" look plus a short label with the space's name.
3. **Placement:** the space menu opens world-locked about 1–1.5 m along the controller direction, 10–20° below eye level. Object menus sit next to the object within 2–3 m; beyond that, pull the menu in to about 1.5 m with a connector line.
4. **Shape:** a pie for up to about 8 actions, a list beyond that. "Leave space" goes in a fixed slot that is not the fastest one, and is confirmed. Desktop gets the same items in the same order.
5. **Dismissal:** same button again, trigger on empty space, Esc, or choosing an item. Don't close on head turn.
6. **Second way in:** a wrist button (VR) and Esc (desktop) also open the space menu.
7. **Fullscreen:** no persistent HUD in the central 30°. Status goes in a body-locked strip 20–30° below eye level, or a small auto-hiding corner on desktop.
8. **Same model on both:** one action set (select, context menu, space menu, back); desktop shortcuts mirror the menu items.
