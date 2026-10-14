# Composition and textual display

Ordinary container subclasses: panel, group, row, column, grid, scroll, tabs. Row/column/grid supply inherited layout defaults; grid declares a positive column count. Scroll declares positive visible_rows. Tabs select an ordered child by its stable identity, using its label; selection is local presentation state, not an input or ontology fact. Tab changes blur the old input and retain controller drafts. Large-text reflow keeps column targets readable. Child enabled state continues to inherit. All children, including inactive tabs, remain in the submitted schema and bindings.

Display subclasses: label, status, help, error; separator; progress with a percent attribute in 0..100. These produce no submitted fields. Progress is current projected state, not a second mutable progress owner. Accessible text accompanies colors and bars. No image/asset path is introduced in this slice.

Attribute defaults use the existing most-specific class relation; conflicting equally specific owners fail rather than choosing a declaration order. Compilation still makes one vocabulary call. Both renderers must support the exact same kinds and tests must exercise tab switching, hidden draft retention, scroll bounds, inherited defaults, no extra fields in submitted answers and unchanged-read cost.

Still outside this slice: images/icon buttons, tables, transient menu/dialog and final headset acceptance. These remain required by the original plan.
