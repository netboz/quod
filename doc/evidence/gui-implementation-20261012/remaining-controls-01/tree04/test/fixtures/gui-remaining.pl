instance_of(quod:gui:form, extra).
instance_of(quod:gui:icon, picture).
instance_of(quod:gui:table, rows).
instance_of(quod:gui:dialog, settings).
instance_of(quod:gui:menu, tools).
instance_of(quod:gui:text_area, note).
instance_of(quod:gui:checkbox, flag).
instance_of(quod:gui:icon_button, apply).
gui_children(extra, [picture, rows, settings, tools, apply]).
gui_children(settings, [note]).
gui_children(tools, [flag]).
attribute(extra, label, <<"Extra controls">>).
attribute(picture, label, <<"Picture">>).
attribute(rows, label, <<"Measurements">>).
attribute(settings, label, <<"Settings">>).
attribute(tools, label, <<"Tools">>).
attribute(note, label, <<"Notes">>).
attribute(flag, label, <<"Flag">>).
attribute(apply, label, <<"Apply">>).
attribute(rows, headings, [<<"Channel">>, <<"Value">>]).
attribute(rows, multiple, true).
attribute(rows, options, [option(row(a), [<<"Alpha">>, <<"10">>]), option(row(b), [<<"Beta">>, <<"20">>])]).
attribute(picture, image, asset(<<"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa">>, <<"image/jpeg">>)).
attribute(apply, image, asset(<<"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa">>, <<"image/jpeg">>)).
gui_form(extra, [field(rows, Rows), field(note, Note), field(flag, Flag)], submit(apply, entered(Rows, Note, Flag))).
