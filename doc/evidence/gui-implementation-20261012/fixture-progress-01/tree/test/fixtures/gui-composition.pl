instance_of(quod:gui:form, composed).
instance_of(quod:gui:tabs, pages).
instance_of(quod:gui:panel, first).
instance_of(quod:gui:group, second).
instance_of(quod:gui:grid, inputs).
instance_of(quod:gui:row, summary).
instance_of(quod:gui:column, explanation).
instance_of(quod:gui:scroll, details).
instance_of(quod:gui:text_box, left).
instance_of(quod:gui:text_area, right).
instance_of(quod:gui:label, title).
instance_of(quod:gui:status, state).
instance_of(quod:gui:help, hint).
instance_of(quod:gui:error, problem).
instance_of(quod:gui:separator, divider).
instance_of(quod:gui:progress, loading).
instance_of(quod:gui:button, apply).
gui_children(composed, [pages, apply]).
gui_children(pages, [first, second]).
gui_children(first, [inputs, summary]).
gui_children(inputs, [left, right]).
gui_children(summary, [state, loading]).
gui_children(second, [explanation, details]).
gui_children(explanation, [title, hint]).
gui_children(details, [problem, divider]).
attribute(composed, label, <<"Composed form">>).
attribute(pages, label, <<"Pages">>).
attribute(first, label, <<"First">>).
attribute(second, label, <<"Second">>).
attribute(inputs, label, <<"Inputs">>).
attribute(summary, label, <<"Summary">>).
attribute(explanation, label, <<"Explanation">>).
attribute(details, label, <<"Details">>).
attribute(left, label, <<"Left">>).
attribute(right, label, <<"Right">>).
attribute(title, label, <<"Title">>).
attribute(state, label, <<"Ready">>).
attribute(hint, label, <<"Help">>).
attribute(problem, label, <<"Error details">>).
attribute(divider, label, <<"End of details">>).
attribute(loading, label, <<"Loading">>).
attribute(apply, label, <<"Apply">>).
attribute(inputs, columns, 3).
attribute(details, visible_rows, 2).
attribute(loading, percent, 65).
gui_form(composed, [field(left, Left), field(right, Right)], submit(apply, entered(Left, Right))).
