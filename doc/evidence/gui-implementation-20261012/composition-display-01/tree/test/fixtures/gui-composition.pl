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
attribute(Id, label, Text) :- member(Id-Text,
    [composed-<<"Composed form">>, pages-<<"Pages">>, first-<<"First">>, second-<<"Second">>,
     inputs-<<"Inputs">>, summary-<<"Summary">>, explanation-<<"Explanation">>, details-<<"Details">>,
     left-<<"Left">>, right-<<"Right">>, title-<<"Title">>, state-<<"Ready">>, hint-<<"Help">>,
     problem-<<"Error details">>, divider-<<"End of details">>, loading-<<"Loading">>, apply-<<"Apply">>]).
attribute(inputs, columns, 3).
attribute(details, visible_rows, 2).
attribute(loading, percent, 65).
gui_form(composed, [field(left, Left), field(right, Right)], submit(apply, entered(Left, Right))).
