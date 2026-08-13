// The BBSVX house palette.  These five values are the single source of truth
// for both the DOM (mirrored as CSS custom properties in style.css) and the
// Babylon scene; nothing in the client may introduce another colour literal.
//
// Semantic roles follow doc/client-world-direction.md §6.5: red carries
// action/transition, gold its manifested effect, green material/growing state,
// navy the receptive ground, grey-blue an unresolved or secondary entry.
export const PALETTE = {
  navy: '#0B3954',
  greyBlue: '#848FA5',
  green: '#698F3F',
  gold: '#F9C80E',
  red: '#C14953',
}
