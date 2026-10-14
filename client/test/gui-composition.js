import { readGuiView } from '../src/world.js'
export const composedView = () => readGuiView(`component(composed,form,[property(label,<<"Composed">>)],[
  component(pages,tabs,[property(label,<<"Pages">>)],[
    component(first,panel,[property(label,<<"First">>)],[
      component(inputs,grid,[property(label,<<"Inputs">>),property(layout,grid),property(columns,3)],[
        component(left,text_box,[property(label,<<"Left">>)],[]),
        component(right,text_box,[property(label,<<"Right">>)],[])]),
      component(loading,progress,[property(label,<<"Loading">>),property(percent,65)],[])]),
    component(second,group,[property(label,<<"Second">>)],[
      component(details,scroll,[property(label,<<"Details">>),property(visible_rows,2)],[
        ${Array.from({length:12}, (_, i) => `component(line(${i}),label,[property(label,<<"Line ${i}">>)],[])`).join(',')}]),
      component(summary,row,[property(label,<<"Summary">>),property(layout,row)],[
        component(state,status,[property(label,<<"Ready">>)],[]),
        component(explanation,column,[property(label,<<"Explanation">>)],[
          component(hint,help,[property(label,<<"Help text">>)],[]),
          component(problem,error,[property(label,<<"Error details">>)],[]),
          component(divider,separator,[property(label,<<"End of details">>)],[])])])])])])`)
