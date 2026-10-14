import { readGuiView } from '../src/world.js'

export const inputVariants = () => readGuiView(`component(inputs,form,[property(label,<<"Input variants">>)],[
  component(notes,text_area,[property(label,<<"Notes">>),property(max_bytes,12)],[]),
  component(count,number_input,[property(label,<<"Count">>),property(range,range(-2,8,3))],[]),
  component(agree,checkbox,[property(label,<<"Agreement">>),property(required,true)],[]),
  component(power,toggle,[property(label,<<"Power">>)],[]),
  component(radio,radio_group,[property(label,<<"Radio">>),property(options,[option(a,<<"Alpha">>),option(b,<<"Beta">>)])],[]),
  component(items,selectable_list,[property(label,<<"Items">>),property(multiple,true),property(options,[option(item(a),<<"Item A">>),option(item(b),<<"Item B">>)])],[])])`)
export const inputDefaults = () => ({ notes: '', count: '-2', agree: 'false', power: 'false', radio: 'a', items: '[]' })
