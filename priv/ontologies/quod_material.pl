%% Physical material knowledge. Appearance is owned by material eidolons.
%% Quantity conversion uses the exact measure vocabulary supplied at founding.
acl_sovereign(quod:material).
can_invoke(Goal, _, _, _) :- material_query(Goal).
can_invoke((current_ontology_identity(_, _), Goal), _, _, _) :- material_query(Goal).
can_invoke(_, node(Key), _, _) :- peer_admitted(Key, _, _, Key).
can_join(_, _, Key) :- peer_ready(Key).

material_query(isa(_, _)).
material_query(material_class(_)).
material_query(most_specific_classes(_, _, _)).
material_query(property_unit(_, _)).
material_query(material_property(_, _, _, _, _)).
material_query(property_in(_, _, _, _, _, _)).
material_query(have_attribute(_, _, _)).
material_query(attribute(_, _, _)).

isa(material, thing).
isa(wood, material).
isa(oak_wood, wood).
isa(american_red_oak, oak_wood).
isa(northern_red_oak, american_red_oak).
isa(stone, material).
isa(granite, stone).
isa(limestone, stone).
isa(marble, stone).
isa(metal, material).
isa(steel, metal).
isa(bronze, metal).

%% `isa/2` has the shared transitive Web Ontology semantics. The material
%% ontology declares only its taxonomy and material properties.
material_class(Class) :-
    findall(C, isa(C, _), Raw), sort(Raw, Classes), member(Class, Classes),
    isa(Class, material).

property_unit(density, <<"kg/m3">>).
property_unit(temperature, <<"K">>).
property_unit(moisture_content, <<"percent">>).
property_unit(thermal_conductivity, <<"W/(m K)">>).
property_unit(specific_heat, <<"J/(kg K)">>).
property_unit(elastic_modulus, <<"Pa">>).

%% Property claims have explicit scope, conditions and evidence. They do not
%% automatically apply to all ancestors or to every sample of a material.
material_property(northern_red_oak, density, q(705, <<"kg/m3">>),
    [moisture_content(q(12, <<"percent">>))],
    reference(<<"https://www.americanhardwood.org/en/american-hardwood/american-red-oak">>,
              <<"Quercus rubra: average weight at 12% moisture content">>)).

property_in(Material, Property, Conditions, Unit, Converted, Evidence) :-
    material_property(Material, Property, Value, Conditions, Evidence),
    property_unit(Property, BaseUnit),
    measure_vocabulary(Namespace, Anchor),
    Namespace::(current_ontology_identity(Namespace, Anchor), commensurable(Unit, BaseUnit)),
    convert_property(Value, Namespace, Anchor, Unit, Converted).
convert_property(q(Value, From), Ns, Anchor, Unit, q(Converted, Unit)) :-
    Ns::(current_ontology_identity(Ns, Anchor), convert(Value, From, Unit, Converted)).
convert_property(range(q(Low, From), q(High, From)), Ns, Anchor, Unit,
                 range(q(L, Unit), q(H, Unit))) :-
    Ns::(current_ontology_identity(Ns, Anchor), convert(Low, From, Unit, L)),
    Ns::(current_ontology_identity(Ns, Anchor), convert(High, From, Unit, H)).

have_attribute(material, Property, quantity(Unit)) :- property_unit(Property, Unit).
attribute(Material, Property, claim(Value, Conditions, Evidence)) :-
    material_property(Material, Property, Value, Conditions, Evidence).
