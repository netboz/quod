-module(quod_physics_coordinates).
-moduledoc "Exact world millimetres and bounded local simulation coordinates.".
-export([origin/4,local/3,canonical/2,subtract/2,add/2,plan/7,body_points/5,regions/1,shape/3,chunk_box/3]).

chunk_box(Centre,Radius,Width) ->
    {list_to_tuple([floor_div(N-Radius,Width) || N <- tuple_to_list(Centre)]),
     list_to_tuple([floor_div(N+Radius,Width) || N <- tuple_to_list(Centre)])}.

%% Alignment keeps each terrain lattice's chunk addresses integral in the
%% translated native frame. The existing coordinate allowance bounds the live
%% window; it does not bound authored absolute coordinates.
origin(Points,Widths,Current,Limit) when is_list(Points),is_list(Widths),
                                      is_integer(Limit),Limit > 0 ->
    try
        true = lists:all(fun point/1,[Current|Points]),
        true = lists:all(fun(W) -> is_integer(W) andalso W > 0 end,Widths),
        Grid = lists:foldl(fun(W,G) -> W div gcd(W,G)*G end,1,Widths),
        Axes = [[element(I,P) || P <- Points] || I <- [1,2,3]],
        Selected = [choose(A,element(I,Current),Grid,Limit) || {A,I} <- lists:zip(Axes,[1,2,3])],
        {ok,list_to_tuple(Selected)}
    catch throw:outside_window -> {error,coordinate_allowance};
          error:_ -> {error,invalid_coordinate_frame} end;
origin(_,_,_,_) -> {error,invalid_coordinate_frame}.

choose([],Current,Grid,_) -> floor_div(Current,Grid)*Grid;
choose(Values,Current,Grid,Limit) ->
    Low = lists:min(Values), High = lists:max(Values),
    case Current rem Grid =:= 0 andalso
         max(abs(Low-Current),abs(High-Current))*2 =< Limit of
        true -> Current;
        false ->
            Centre = floor_div(Low+High,2), Base = floor_div(Centre,Grid)*Grid,
            Candidates = lists:sort([{max(abs(Low-C),abs(High-C)),abs(C-Current),C}
                                     || C <- [Base,Base+Grid]]),
            case Candidates of [{Distance,_,Chosen}|_] when Distance =< Limit -> Chosen;
                               _ -> throw(outside_window) end
    end.

local({frame_mm,Base,{A,B,C}},Origin,Limit) when is_integer(Limit),Limit > 0 ->
    case point(Base) andalso point(Origin) of
        true ->
            {X,Y,Z}=subtract(Base,Origin),
            Position={X+A,Y+B,Z+C},
            case lists:all(fun(N) -> is_number(N) andalso abs(N) =< Limit end,tuple_to_list(Position)) of
                true -> {PX,PY,PZ}=Position,{ok,{PX/1000,PY/1000,PZ/1000}};
                false -> {error,coordinate_allowance}
            end;
        false -> {error,invalid_coordinate_frame}
    end;
local(P,Origin,Limit) when is_integer(Limit),Limit > 0 ->
    case point(P) andalso point(Origin) of
        true ->
            {X,Y,Z} = subtract(P,Origin),
            case max(abs(X),max(abs(Y),abs(Z))) =< Limit of
                true -> {ok,{X/1000,Y/1000,Z/1000}};
                false -> {error,coordinate_allowance}
            end;
        false -> {error,invalid_coordinate_frame}
    end;
local(_,_,_) -> {error,invalid_coordinate_frame}.

canonical({X,Y,Z},Origin) -> add({round(X*1000),round(Y*1000),round(Z*1000)},Origin).
subtract({X,Y,Z},{A,B,C}) -> {X-A,Y-B,Z-C}.
add({X,Y,Z},{A,B,C}) -> {X+A,Y+B,Z+C}.
point({X,Y,Z}) -> is_integer(X) andalso is_integer(Y) andalso is_integer(Z);
point(_) -> false.
gcd(A,0) -> A;
gcd(A,B) -> gcd(B,A rem B).
floor_div(A,B) -> (A-(A rem B)+case A rem B < 0 of true -> -B; false -> 0 end) div B.


%% Canonical inputs remain immutable. A retained body's insertion pose is only
%% a native identity token; rebasing must never reapply its authored baseline.
plan(Bodies,Restores,Previous,Frame,Current,Limit,Targets) ->
    try
        Saved = maps:from_list([{Id,Position} || {Id,_,{Position,_},_,_} <- Restores]),
        {TerrainPoints,Widths} = regions([Shape || {_,_,_,_,Shape,_} <- Bodies]),
        Points = body_points(Bodies,Saved,Previous,Frame,Current)++TerrainPoints,
        %% The old lattice alignment is also needed while translating retained
        %% pieces, even when this installation replaces their specification.
        OldWidths = [S*8 || {_,{_,_,_,_,{terrain,S,_},_}} <- maps:values(Previous)],
        {ok,Origin} = checked(origin(Targets++Points,Widths++OldWidths,Current,Limit)),
        {Native,Cache} = lists:mapfoldl(fun(Row = {Id,R,K,{world_mm,P,A},Shape,D},Acc) ->
            Prepared = case Shape of
                {terrain,S,Chunks} ->
                    {Id,R,K,{{0.0,0.0,0.0},A},shape({terrain,S,Chunks},Origin,Limit),D};
                _ -> case maps:get(Id,Previous,none) of
                    {Row,Kept} -> Kept;
                    _ -> {ok,Position} = checked(local(maps:get(Id,Saved,P),Origin,Limit)),{Id,R,K,{Position,A},Shape,D}
                end
            end,
            {Prepared,Acc#{Id => {Row,Prepared}}}
        end,#{},Bodies),
        Delta = case map_size(Previous) of 0 -> {0,0,0}; _ -> subtract(Origin,Current) end,
        {ok,Origin,Delta,Native,Cache}
    catch throw:{coordinate_error,Reason} -> {error,Reason};
          error:_ -> {error,invalid_coordinate_frame} end.

checked({error,Reason}) -> throw({coordinate_error,Reason});
checked(Result) -> Result.

%% Both installation and prospective viewer demand use current retained poses;
%% an authored insertion baseline cannot move the numerical window backwards.
body_points(Bodies,Saved,Previous,Frame,Current) ->
    Poses = case Frame of none -> #{};
        #{poses := Rows} -> maps:from_list([{Id,P} || {Id,_,world,P,_,_} <- Rows]) end,
    lists:flatmap(fun
        ({_,_,_,_,{terrain,_,_},_}) -> [];
        (Row = {Id,_,_,{world_mm,P,_},_,_}) ->
            Point = case {maps:get(Id,Previous,none),maps:find(Id,Poses)} of
                {{Row,_},{ok,Local}} -> canonical(Local,Current);
                _ -> maps:get(Id,Saved,P)
            end,
            point_bounds(Point)
    end,Bodies).

point_bounds({frame_mm,Base,{X,Y,Z}}) ->
    [add(Base,{floor(X)-1,floor(Y)-1,floor(Z)-1}),
     add(Base,{ceil(X)+1,ceil(Y)+1,ceil(Z)+1})];
point_bounds(Point) -> [add(Point,{-1,-1,-1}),add(Point,{1,1,1})].


regions(Shapes) ->
    lists:foldl(fun
        ({terrain,S,Chunks},{Points,Widths}) ->
            Width = S*8,
            {[P || {C,_} <- Chunks,P <- [C,add(C,{Width,Width,Width})]]++Points,[Width|Widths]};
        (_Shape,Acc) -> Acc
    end,{[],[]},Shapes).

shape({terrain,S,Chunks},Origin,Limit) ->
    {terrain,S,[begin
        {ok,_} = checked(local(C,Origin,Limit)),
        {ok,_} = checked(local(add(C,{S*8,S*8,S*8}),Origin,Limit)),
        {subtract(C,Origin),Handle}
    end || {C,Handle} <- Chunks]};
shape(Shape,_,_) -> Shape.
