-module(quod_physics_frames).
-moduledoc "Pure parent-first physical frame composition at the native boundary.".
-export([pose/2]).
-ifdef(TEST).
-export([rotation/1,rotate/2]).
-endif.

%% Keep the first translation exact until the native window is selected. Only
%% relative offsets become binary64; large absolute origins retain their bits.
pose(Frames,Local) ->
    [{Base,First}|Rest]=[authored(T)||T<-Frames++[Local]],
    {Offset,Q}=lists:foldl(fun({P,R},{At,Before}) ->
        {add(At,rotate(Before,P)),multiply(Before,R)}
    end,{{0.0,0.0,0.0},First},Rest),
    {X,Y,Z}=Offset, Shift={round(X),round(Y),round(Z)},
    {world_mm,{frame_mm,add(Base,Shift),{X-element(1,Shift),Y-element(2,Shift),Z-element(3,Shift)}},euler(Q)}.

authored({transform,X,Y,Z,RX,RY,RZ}) ->
    {{X,Y,Z},rotation({RX*math:pi()/180,RY*math:pi()/180,RZ*math:pi()/180})};
authored({vector,X,Y,Z}) -> {{X,Y,Z},{0.0,0.0,0.0,1.0}};
authored({pose,{vector,X,Y,Z},{rotation,RX,RY,RZ}}) ->
    {{X,Y,Z},rotation({RX/1000,RY/1000,RZ/1000})}.

%% Existing handedness/order: local X, then Y, then Z. Never add component
%% angles. The native API takes XYZ radians, so decompose the composed rotation
%% only here; authored Prolog frames and streamed quaternions stay unchanged.
rotation({X,Y,Z}) ->
    multiply(multiply({0.0,0.0,math:sin(Z/2),math:cos(Z/2)},
                      {0.0,math:sin(Y/2),0.0,math:cos(Y/2)}),
             {math:sin(X/2),0.0,0.0,math:cos(X/2)}).
multiply({X,Y,Z,W},{A,B,C,D}) ->
    normal({W*A+X*D+Y*C-Z*B,W*B-X*C+Y*D+Z*A,
            W*C+X*B-Y*A+Z*D,W*D-X*A-Y*B-Z*C}).
normal({X,Y,Z,W}) ->
    Length=math:sqrt(X*X+Y*Y+Z*Z+W*W),
    {X/Length,Y/Length,Z/Length,W/Length}.
rotate({X,Y,Z,W},{A,B,C}) ->
    TX=2*(Y*C-Z*B), TY=2*(Z*A-X*C), TZ=2*(X*B-Y*A),
    {A+W*TX+Y*TZ-Z*TY,B+W*TY+Z*TX-X*TZ,C+W*TZ+X*TY-Y*TX}.
euler({X,Y,Z,W}) ->
    Sin=max(-1.0,min(1.0,2*(W*Y-Z*X))),
    M21=2*(Y*Z+W*X), M22=1-2*(X*X+Y*Y),
    Cos=math:sqrt(M21*M21+M22*M22),
    case Cos > 1.0e-12 of
        true -> {math:atan2(M21,M22),math:atan2(Sin,Cos),
                 math:atan2(2*(X*Y+W*Z),1-2*(Y*Y+Z*Z))};
        %% At gimbal lock use roll zero and the matrix's remaining yaw.
        %% Matrix entries make q and -q produce identical native rows.
        false -> {0.0,math:atan2(Sin,Cos),math:atan2(-2*(X*Y-W*Z),1-2*(X*X+Z*Z))}
    end.
add({X,Y,Z},{A,B,C}) -> {X+A,Y+B,Z+C}.
