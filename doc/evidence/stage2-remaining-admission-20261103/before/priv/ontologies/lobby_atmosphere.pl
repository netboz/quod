%% Compose with lobby_instance.pl and gui_instance.pl. The application supplies
%% gui_question_policy/3 and atmosphere_panorama(Value, Label) choices.
%% Component identities are local terms, including when several skies exist.
instance_of(quod:gui:form, atmosphere(S)) :- instance_of(sky_sphere, S).
instance_of(quod:gui:container, appearance(S)) :- instance_of(sky_sphere, S).
instance_of(quod:gui:container, lighting(S)) :- instance_of(sky_sphere, S).
instance_of(quod:gui:text_box, preset(S)) :- instance_of(sky_sphere, S).
instance_of(quod:gui:selection, panorama(S)) :- instance_of(sky_sphere, S).
instance_of(quod:gui:slider, brightness(S)) :- instance_of(sky_sphere, S).
instance_of(quod:gui:rotary_knob, rotation(S)) :- instance_of(sky_sphere, S).
instance_of(quod:gui:button, apply_atmosphere(S)) :- instance_of(sky_sphere, S).

gui_children(atmosphere(S), [appearance(S), lighting(S), apply_atmosphere(S)]).
gui_children(appearance(S), [preset(S), panorama(S)]).
gui_children(lighting(S), [brightness(S), rotation(S)]).
attribute(atmosphere(_), label, <<"Lobby atmosphere">>).
attribute(appearance(_), label, <<"Appearance">>).
attribute(lighting(_), label, <<"Lighting">>).
attribute(preset(_), label, <<"Preset name">>).
attribute(preset(_), required, true).
attribute(preset(_), max_bytes, 128).
attribute(panorama(_), label, <<"Panorama">>).
attribute(panorama(_), options, Options) :-
    findall(option(Value, Label), atmosphere_panorama(Value, Label), Options).
attribute(brightness(_), label, <<"Brightness">>).
attribute(brightness(_), range, range(0, 1000, 1)).
attribute(brightness(_), unit, permille).
attribute(rotation(_), label, <<"Rotation">>).
attribute(rotation(_), range, range(0, 359, 1)).
attribute(rotation(_), unit, degrees).
attribute(apply_atmosphere(_), label, <<"Apply atmosphere">>).

gui_form(atmosphere(S),
    [field(preset(S), Name), field(panorama(S), Panorama),
     field(brightness(S), Brightness), field(rotation(S), Rotation)],
    submit(apply_atmosphere(S), atmosphere_entered(S, Name, Panorama, Brightness, Rotation))).
gui_initial(atmosphere(S), preset(S), Name) :- one_attribute(S, preset_name, Name).
gui_initial(atmosphere(S), panorama(S), Value) :- one_attribute(S, panorama, Value).
gui_initial(atmosphere(S), brightness(S), Value) :- one_attribute(S, brightness, Value).
gui_initial(atmosphere(S), rotation(S), Value) :- one_attribute(S, rotation, Value).

%% gui_continue validates and binds all fields before invoking this private
%% continuation. Its outer transaction includes question and HUD consumption.
%% Replacing attributes preserves sky identity, geometry and unrelated state.
atmosphere_entered(S, Name, Panorama, Brightness, Rotation) :-
    current_principal(Actor), gui_question_policy(atmosphere(S), _, Actor),
    one_attribute(S, preset_name, OldName), one_attribute(S, panorama, OldPanorama),
    one_attribute(S, brightness, OldBrightness), one_attribute(S, rotation, OldRotation),
    retract(attribute(S, preset_name, OldName)), assertz(attribute(S, preset_name, Name)),
    retract(attribute(S, panorama, OldPanorama)), assertz(attribute(S, panorama, Panorama)),
    retract(attribute(S, brightness, OldBrightness)), assertz(attribute(S, brightness, Brightness)),
    retract(attribute(S, rotation, OldRotation)), assertz(attribute(S, rotation, Rotation)).
