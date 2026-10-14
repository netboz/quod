instance_of(quod:gui:form, settings).
instance_of(quod:gui:container, tuning).
instance_of(quod:gui:text_box, name).
instance_of(quod:gui:selection, mode).
instance_of(fine_level, level).
isa(fine_level, quod:gui:slider).
instance_of((quod:gui):rotary_knob, angle).
instance_of(quod:gui:button, apply).

gui_children(settings, [name, mode, tuning, apply]).
gui_children(tuning, [level, angle]).
attribute(settings, label, <<"Instrument settings">>).
attribute(tuning, label, <<"Tuning">>).
attribute(name, label, <<"Name">>).
attribute(name, required, true).
attribute(mode, label, <<"Mode">>).
attribute(mode, options, [option(sine, <<"Sine">>), option(square, <<"Square">>)]).
attribute(level, label, <<"Level">>).
attribute(level, range, range(0, 100, 5)).
attribute(angle, label, <<"Phase">>).
attribute(angle, range, range(0, 359, 1)).
attribute(angle, unit, degrees).
attribute(apply, label, <<"Apply">>).

gui_form(settings,
    [field(name, Name), field(mode, Mode), field(level, Level), field(angle, Angle)],
    submit(apply, settings_entered(Name, Mode, Level, Angle))).
gui_initial(settings, name, <<"Oscillator">>).
gui_initial(settings, mode, sine).
gui_initial(settings, level, 50).
gui_initial(settings, angle, 90).
