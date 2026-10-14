import { readGuiView } from '../src/world.js'

export const remainingView = digest => readGuiView(`component(extra,form,[property(label,<<"Remaining controls">>)],[
  component(origins,tabs,[property(label,<<"Origins">>)],[
    component(origin,panel,[property(label,<<"Origin">>)],[component(outside,text_box,[property(label,<<"Outside">>)],[])]),
    component(other_origin,panel,[property(label,<<"Other origin">>)],[component(other_label,label,[property(label,<<"Other view">>)],[])])]),
  component(picture,image,[property(label,<<"Verified image">>),property(image,asset(<<"${digest}">>,<<"image/jpeg">>))],[]),
  component(rows,table,[property(label,<<"Measurements">>),property(multiple,true),property(headings,[<<"Channel">>,<<"Value">>]),property(options,[
    ${Array.from({length:12}, (_, i) => `option(row(${i}),[<<"Channel ${i}">>,<<"${i * 10}">>])`).join(',')}])],[]),
  component(settings,dialog,[property(label,<<"Settings">>)],[
    component(note,text_area,[property(label,<<"Dialog notes">>)],[]),
    component(apply,button,[property(label,<<"Apply inside">>)],[])]),
  component(tools,menu,[property(label,<<"Tools">>)],[
    component(flag,checkbox,[property(label,<<"Flag">>)],[]),
    component(icon_action,button,[property(label,<<"Icon action">>),property(image,asset(<<"${digest}">>,<<"image/jpeg">>))],[])])])`)

// Generated fixture bytes use the same verified asset URL and digest contract.
export async function guiAssetFixture() {
  const canvas = document.createElement('canvas')
  canvas.width = 8; canvas.height = 8
  const context = canvas.getContext('2d')
  context.fillStyle = '#C5E7A0'; context.fillRect(0, 0, 8, 8)
  const blob = await new Promise(resolve => canvas.toBlob(resolve, 'image/jpeg'))
  const bytes = await blob.arrayBuffer()
  const hash = new Uint8Array(await crypto.subtle.digest('SHA-256', bytes))
  const digest = [...hash].map(n => n.toString(16).padStart(2, '0')).join('')
  const original = window.fetch
  let reads = 0
  window.fetch = (url, options) => {
    if (url === `/assets/textures/${digest}.jpg`) { reads++; return Promise.resolve(new Response(bytes)) }
    return original(url, options)
  }
  return { digest, reads: () => reads, restore: () => { window.fetch = original } }
}
