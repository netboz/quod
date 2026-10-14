%% Nonphysical application example. Compose gui_instance.pl and supply an
%% instrument instance, one current configuration and gui_question_policy/3.
%% There is no lobby, world, physics or client dependency.
instance_of(quod:gui:form, instrument_settings(I)) :- instance_of(instrument, I).
instance_of(quod:gui:tabs, sections(I)) :- instance_of(instrument, I).
instance_of(quod:gui:container, general(I)) :- instance_of(instrument, I).
instance_of(quod:gui:container, tuning(I)) :- instance_of(instrument, I).
instance_of(quod:gui:container, routing(I)) :- instance_of(instrument, I).
instance_of(quod:gui:text_box, run_name(I)) :- instance_of(instrument, I).
instance_of(quod:gui:text_area, notes(I)) :- instance_of(instrument, I).
instance_of(quod:gui:selection, mode(I)) :- instance_of(instrument, I).
instance_of(quod:gui:toggle, enabled(I)) :- instance_of(instrument, I).
instance_of(quod:gui:table, channels(I)) :- instance_of(instrument, I).
instance_of(quod:gui:slider, gain(I)) :- instance_of(instrument, I).
instance_of(quod:gui:rotary_knob, phase(I)) :- instance_of(instrument, I).
instance_of(quod:gui:button, apply_instrument(I)) :- instance_of(instrument, I).

gui_children(instrument_settings(I), [sections(I), apply_instrument(I)]).
gui_children(sections(I), [general(I), tuning(I), routing(I)]).
gui_children(general(I), [run_name(I), mode(I), enabled(I), notes(I)]).
gui_children(tuning(I), [gain(I), phase(I)]).
gui_children(routing(I), [channels(I)]).
attribute(instrument_settings(_), label, <<"Instrument configuration">>).
attribute(sections(_), label, <<"Configuration sections">>).
attribute(general(_), label, <<"General">>).
attribute(tuning(_), label, <<"Tuning">>).
attribute(routing(_), label, <<"Channels">>).
attribute(run_name(_), label, <<"Run name">>).
attribute(run_name(_), required, true).
attribute(run_name(_), max_bytes, 128).
attribute(notes(_), label, <<"Notes">>).
attribute(notes(_), max_bytes, 2048).
attribute(mode(_), label, <<"Mode">>).
attribute(mode(_), options, [option(sweep, <<"Sweep">>), option(hold, <<"Hold">>)]).
attribute(enabled(_), label, <<"Enabled">>).
attribute(channels(_), label, <<"Active channels">>).
attribute(channels(_), options,
    [option(left, [<<"Left">>, <<"Reference">>]), option(right, [<<"Right">>, <<"Measurement">>])]).
attribute(channels(_), headings, [<<"Channel">>, <<"Purpose">>]).
attribute(channels(_), multiple, true).
attribute(channels(_), required, true).
attribute(gain(_), label, <<"Gain">>).
attribute(gain(_), range, range(0, 100, 1)).
attribute(gain(_), unit, percent).
attribute(phase(_), label, <<"Phase">>).
attribute(phase(_), range, range(0, 359, 1)).
attribute(phase(_), unit, degrees).
attribute(apply_instrument(_), label, <<"Apply configuration">>).

gui_form(instrument_settings(I),
    [field(run_name(I), Name), field(mode(I), Mode), field(gain(I), Gain),
     field(phase(I), Phase), field(enabled(I), Enabled), field(channels(I), Channels), field(notes(I), Notes)],
    submit(apply_instrument(I), instrument_entered(I, Name, Mode, Gain, Phase, Enabled, Channels, Notes))).
gui_initial(instrument_settings(I), Field, Value) :-
    current_instrument_configuration(I, Name, Mode, Gain, Phase, Enabled, Channels, Notes),
    member(field(Field, Value), [field(run_name(I), Name), field(mode(I), Mode), field(gain(I), Gain),
        field(phase(I), Phase), field(enabled(I), Enabled), field(channels(I), Channels), field(notes(I), Notes)]).

current_instrument_configuration(I, Name, Mode, Gain, Phase, Enabled, Channels, Notes) :-
    findall(config(N, M, G, P, E, C, T), instrument_configuration(I, N, M, G, P, E, C, T),
            [config(Name, Mode, Gain, Phase, Enabled, Channels, Notes)]).

%% The private continuation is reached through shared gui_continue under the
%% responsible actor's ordinary authority. Accepted answers replace current
%% domain state instead of accumulating a GUI answer history.
instrument_entered(I, Name, Mode, Gain, Phase, Enabled, Channels, Notes) :-
    current_principal(Actor), gui_question_policy(instrument_settings(I), _, Actor),
    current_instrument_configuration(I, N, M, G, P, E, C, T),
    retract(instrument_configuration(I, N, M, G, P, E, C, T)),
    assertz(instrument_configuration(I, Name, Mode, Gain, Phase, Enabled, Channels, Notes)).
