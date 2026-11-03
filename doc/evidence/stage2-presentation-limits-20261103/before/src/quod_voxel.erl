-module(quod_voxel).
-moduledoc "Pure terrain sampling and surface arithmetic over explicit versioned inputs.".
-export([sample/4, surface/4, edit/5, brush_chunks/3, chunk/4, chunk_surface/3]).
-export([prepare/5,resident_chunks/3,prioritize_chunks/3]).

-define(Q, 65536).
-define(CHUNK, 8).

%% Allowances are supplied by ontology policy. They count output samples,
%% operator evaluations, worst-case hash evaluations and packed output bytes.
sample({field_v1, Seed, Spacing, Operators, Material},
       {vector, X, Y, Z}, {dimensions, Nx, Ny, Nz},
       {sampling_limits, Samples, Operations, Hashes, Bytes}) ->
    try
        true = is_integer(Seed) andalso Seed >= 0 andalso Seed < (1 bsl 64),
        true = spacing(Spacing),
        true = lists:all(fun is_integer/1, [X,Y,Z]),
        true = lists:all(fun(V) -> is_integer(V) andalso V > 0 end,[Nx,Ny,Nz]),
        true = material(Material),
        true = is_list(Operators) andalso Operators =/= [],
        [Base | Layers] = Operators,
        true = valid_base(Base),
        true = lists:all(fun valid_layer/1,Layers),
        true = lists:all(fun allowance/1,[Samples,Operations,Hashes,Bytes]),
        Count = Nx*Ny*Nz,
        charge(samples,Count,Samples),
        charge(operator_evaluations,Count*lists:sum([operator_cost(O) || O <- Operators]),Operations),
        HashCount = Count*lists:sum([hash_cost(O) || O <- Layers]),
        charge(hash_evaluations,HashCount,Hashes),
        charge(sample_bytes,Count*3,Bytes),
        {Density,Materials,_Cache} = samples(0,Count,{Nx,Ny}, {X,Y,Z},
            Seed,Spacing,Operators,Material,#{},[],[]),
        {ok,{samples_v1,list_to_binary(lists:reverse(Density)),
                        iolist_to_binary(lists:reverse(Materials))}}
    catch
        throw:{voxel_allowance,_,_,_} = Reason -> {error,Reason};
        error:{badmatch,false} -> {error,invalid_voxel_field}
    end;
sample(_,_,_,_) -> {error,invalid_voxel_field}.

surface({samples_v1,Density,Materials}, {dimensions,Nx,Ny,Nz}, Spacing,
        {surface_limits,Cells,Vertices,Triangles})
  when is_binary(Density), is_binary(Materials), is_integer(Nx),Nx > 1,is_integer(Ny),Ny > 1,
       is_integer(Nz),Nz > 1 ->
    case byte_size(Materials) =:= Nx*Ny*Nz*2 andalso spacing(Spacing)
         andalso lists:all(fun allowance/1,[Cells,Vertices,Triangles])
         andalso lists:all(fun(V) -> V =< 16#ffffffff end,[Nx-1,Ny-1,Nz-1])
         andalso lists:all(fun(V) -> V < (1 bsl 64) end,[Cells,Vertices,Triangles]) of
        false -> {error,invalid_voxel_field};
        true -> case quod_physics_native:voxel_surface(Density,{Nx-1,Ny-1,Nz-1},Spacing,
                                                       {Cells,Vertices,Triangles}) of
            {ok,{Vs,Ts}} -> {ok,{surface,[{vector,X,Y,Z} || {X,Y,Z} <- Vs],
                                         [{triangle,A,B,C} || {A,B,C} <- Ts]}};
            Error -> Error
        end
    end;
surface(_,_,_,_) -> {error,invalid_voxel_field}.

%% A patch owns 8^3 lattice sites, not cells plus their duplicated borders.
%% Its sorted records are index:u16, density:i8, material:u16, all big endian.
%% Missing records mean the procedural value; edits never append a history.
edit(Spec = {field_v1,_,S,_,_}, C, {patch_v1,Before}, Brush,
     {edit_limits,Sampling,PatchBytes}) when is_binary(Before) ->
    checked(fun() ->
        true = chunk_coordinate(C) andalso valid_brush(Brush) andalso allowance(PatchBytes),
        charge(patch_bytes,byte_size(Before),PatchBytes),
        Old = decode_patch(Before),
        {X,Y,Z} = chunk_origin(C),
        {samples_v1,D,M} = value(sample(Spec,{vector,X,Y,Z},
                                        {dimensions,?CHUNK,?CHUNK,?CHUNK},Sampling)),
        {Records,Changed} = lists:foldl(fun(I,{Rows,Changes}) ->
            Base = sample_at(D,M,I),
            Current = maps:get(I,Old,Base),
            %% Reject noncanonical redundant records, rather than silently
            %% changing an unchanged patch during an unrelated brush.
            true = not maps:is_key(I,Old) orelse Current =/= Base,
            P = {X+I rem ?CHUNK,Y+(I div ?CHUNK) rem ?CHUNK,Z+I div (?CHUNK*?CHUNK)},
            After = brush(Brush,scale_point(P,S),S,Current),
            Next = case After of Base -> Rows; {V,Mat} -> [<<I:16,V:8/signed,Mat:16>>|Rows] end,
            Delta = case After =:= Current of true -> Changes; false -> [{P,Current,After}|Changes] end,
            {Next,Delta}
        end,{[],[]},lists:seq(0,?CHUNK*?CHUNK*?CHUNK-1)),
        Bytes = iolist_to_binary(lists:reverse(Records)),
        charge(patch_bytes,byte_size(Bytes),PatchBytes),
        DensityChanged = lists:any(fun({_,{A,_},{B,_}}) -> A =/= B end,Changed),
        MaterialChanged = lists:any(fun({_,{_,A},{_,B}}) -> A =/= B end,Changed),
        {edit_v1,{patch_v1,Bytes},DensityChanged,MaterialChanged,
         lists:usort(lists:append([consumers(P) || {P,_,_} <- Changed]))}
    end);
edit(_,_,_,_,_) -> {error,invalid_voxel_field}.

%% Include the distance band's influence: a subtractive sphere changes edge
%% interpolation outside its positive interior, up to one spacing away.
brush_chunks(Brush,S,{chunk_limits,Maximum}) ->
    checked(fun() ->
        true = valid_brush(Brush) andalso spacing(S) andalso allowance(Maximum),
        {Centre,Radius,Margin} = case Brush of
            {dig_sphere,P,R} -> {P,R,S};
            {paint_sphere,P,R,_} -> {P,R,0}
        end,
        {vector,X,Y,Z} = Centre,
        Ranges = [begin
            Low = -floor_div(-(A-Radius-Margin),S),
            High = floor_div(A+Radius+Margin,S),
            {floor_div(Low,?CHUNK),floor_div(High,?CHUNK)}
        end || A <- [X,Y,Z]],
        [{Ax,Bx},{Ay,By},{Az,Bz}] = Ranges,
        Count = max(0,Bx-Ax+1)*max(0,By-Ay+1)*max(0,Bz-Az+1),
        charge(edit_chunks,Count,Maximum),
        [{chunk_v1,Cx,Cy,Cz} || Cx <- lists:seq(Ax,Bx),
                              Cy <- lists:seq(Ay,By),Cz <- lists:seq(Az,Bz)]
    end);
brush_chunks(_,_,_) -> {error,invalid_voxel_field}.

%% The caller supplies current owned patches from its verified snapshot. The
%% 11^3 result includes one sample outside each face for shared gradients.
%% Sampling/meshing consumers retain this immutable result by its inputs.
chunk(Spec,C,Rows,{chunk_limits,Sampling,PatchBytes}) ->
    checked(fun() ->
        true = chunk_coordinate(C) andalso is_list(Rows) andalso allowance(PatchBytes),
        chunk_samples(Spec,C,patches(C,Rows,PatchBytes),Sampling)
    end);
chunk(_,_,_,_) -> {error,invalid_voxel_field}.

patches(C,Rows,Maximum) ->
    Packed = lists:foldl(fun({override,K,{patch_v1,Bin}},Acc) ->
        true = chunk_coordinate(K) andalso nearby(C,K) andalso is_binary(Bin) andalso not maps:is_key(K,Acc),
        Acc#{K => Bin}
    end,#{},Rows),
    charge(patch_bytes,lists:sum([byte_size(B) || B <- maps:values(Packed)]),Maximum),
    maps:map(fun(_,B) -> decode_patch(B) end,Packed).

chunk_samples(Spec,C,Decoded,Sampling) ->
    {X,Y,Z} = chunk_origin(C), N = ?CHUNK+3,
    {samples_v1,D,M} = value(sample(Spec,{vector,X-1,Y-1,Z-1},{dimensions,N,N,N},Sampling)),
    {Density,Materials} = lists:unzip([begin
        P = {X-1+I rem N,Y-1+(I div N) rem N,Z-1+I div (N*N)},
        {Owner,Index} = owner(P),
        {V,Mat} = maps:get(Index,maps:get(Owner,Decoded,#{}),sample_at(D,M,I)),
        {<<V:8/signed>>,<<Mat:16>>}
    end || I <- lists:seq(0,N*N*N-1)]),
    {samples_v1,iolist_to_binary(Density),iolist_to_binary(Materials)}.

%% A neighbor owns sites outside this chunk's halo too. Hash only consumed
%% sites, so an edit there cannot invalidate an unchanged resident surface.
patch_inputs(C,Patches) ->
    {X,Y,Z} = chunk_origin(C),
    lists:sort(maps:fold(fun(K,Patch,Rows) ->
        {A,B,Cz} = chunk_origin(K),
        maps:fold(fun(I,{D,M},Acc) ->
            {Px,Py,Pz} = {A+I rem ?CHUNK,B+(I div ?CHUNK) rem ?CHUNK,Cz+I div (?CHUNK*?CHUNK)},
            case Px >= X-1 andalso Px =< X+9 andalso Py >= Y-1 andalso Py =< Y+9
                 andalso Pz >= Z-1 andalso Pz =< Z+9 of
                true -> [{site,Px,Py,Pz,D,M}|Acc];
                false -> Acc
            end
        end,Rows,Patch)
    end,[],Patches)).

chunk_surface({samples_v1,D,M},S,Limits)
  when is_binary(D),byte_size(D) =:= 1331,is_binary(M),byte_size(M) =:= 2662,
       is_integer(S),S =< 16#ffffffff div 8 ->
    %% Geometry owns eight cells. Halo sites serve gradients and shared input
    %% identity; triangulating them would duplicate neighboring surfaces.
    Sites = [(Z*11+Y)*11+X || Z <- lists:seq(1,9),Y <- lists:seq(1,9),X <- lists:seq(1,9)],
    Density = list_to_binary([binary:at(D,I) || I <- Sites]),
    Materials = iolist_to_binary([binary:part(M,I*2,2) || I <- Sites]),
    surface({samples_v1,Density,Materials},{dimensions,9,9,9},S,Limits);
chunk_surface(_,_,_) -> {error,invalid_voxel_field}.

%% Pure set union under the caller's policy. Check each box before allocating
%% its sites, then charge the actual union as overlapping consumers are merged.
resident_chunks(Initial,Ranges,{chunk_limits,Maximum}) when is_list(Initial),is_list(Ranges) ->
    checked(fun() ->
        true = allowance(Maximum),
        Add = fun(C,Acc) ->
            true = chunk_coordinate(C), Next = Acc#{C => true},
            charge(resident_chunks,map_size(Next),Maximum), Next
        end,
        Start = lists:foldl(Add,#{},Initial),
        Set = lists:foldl(fun({chunk_box,{chunk_v1,X,Y,Z},{chunk_v1,A,B,C}},Acc) ->
            true = lists:all(fun is_integer/1,[X,Y,Z,A,B,C]) andalso X =< A andalso Y =< B andalso Z =< C,
            charge(resident_chunks,(A-X+1)*(B-Y+1)*(C-Z+1),Maximum),
            lists:foldl(fun(I,S0) -> lists:foldl(fun(J,S1) -> lists:foldl(fun(K,S2) ->
                Add({chunk_v1,I,J,K},S2)
            end,S1,lists:seq(Z,C)) end,S0,lists:seq(Y,B)) end,Acc,lists:seq(X,A))
        end,Start,Ranges),
        lists:sort(maps:keys(Set))
    end);
resident_chunks(_,_,_) -> {error,invalid_voxel_field}.

%% Order an already admitted set; this changes no scope or allocation. Nearby
%% chunk shells precede distant ones, with the travel direction breaking ties.
%% Doubled centres keep the comparison exact at arbitrary world coordinates.
prioritize_chunks(Chunks,_Spacing,none) -> Chunks;
prioritize_chunks(Chunks,Spacing,{Centre,Direction}) ->
    Width = Spacing*?CHUNK,
    Ranked = [begin
        Delta = [((2*N+1)*Width)-2*P || {N,P} <- lists:zip([X,Y,Z],tuple_to_list(Centre))],
        Near = lists:max([abs(N) || N <- Delta]),
        Ahead = lists:sum([N*D || {N,D} <- lists:zip(Delta,tuple_to_list(Direction))]),
        {{Near,-Ahead,lists:sum([N*N || N <- Delta]),C},C}
    end || C = {chunk_v1,X,Y,Z} <- Chunks],
    [C || {_,C} <- lists:sort(Ranked)].

%% Called by the existing resource worker with the consumer's previous
%% immutable artifact. There is no cache process or hidden source lookup.
%% Work allowances apply to work actually performed; retained output still
%% has to fit the currently selected geometry/byte allocation.
prepare(Field = {field_v1,_,S,_,_},C,Overrides,
        {prepare_limits,Sampling,{surface_limits,Cells,Vertices,Triangles},PatchBytes,PayloadBytes},Previous)
  when is_list(Overrides) ->
    checked(fun() ->
        true = spacing(S) andalso chunk_coordinate(C) andalso sampling_limits(Sampling),
        true = lists:all(fun allowance/1,[Cells,Vertices,Triangles,PatchBytes,PayloadBytes]),
        true = lists:all(fun(N) -> N < (1 bsl 64) end,[Cells,Vertices,Triangles,PayloadBytes]),
        Patches = patches(C,Overrides,PatchBytes),
        Input = {voxel_resource_v1,Field,C,patch_inputs(C,Patches)},
        Encoded = value(quod_wire_term:encode_canonical(Input)),
        Digest = crypto:hash(sha256,Encoded),
        case Previous of
            #{input_digest := Digest,vertices := V,triangles := T,payload := Payload} ->
                charge(geometry_vertices,V,Vertices), charge(geometry_triangles,T,Triangles),
                charge(geometry_bytes,byte_size(Payload),PayloadBytes),
                {Previous,retained};
            _ ->
                {samples_v1,D,M} = chunk_samples(Field,C,Patches,Sampling),
                Retained = case Previous of #{handle := H} -> [H]; _ -> [] end,
                {Handle,Payload} = value(quod_physics_native:voxel_prepare(D,M,S,
                    {Cells,Vertices,Triangles,PayloadBytes},Retained)),
                <<"QVT1",S:32,T:32,V:32,_/binary>> = Payload,
                {#{input_digest => Digest,output_digest => crypto:hash(sha256,Payload),
                   handle => Handle,payload => Payload,vertices => V,triangles => T},generated}
        end
    end);
prepare(_,_,_,_,_) -> {error,invalid_voxel_field}.

checked(Fun) ->
    try {ok,Fun()} catch
        throw:{voxel_allowance,_,_,_} = Reason -> {error,Reason};
        throw:{voxel_error,Reason} -> {error,Reason};
        error:{badmatch,false} -> {error,invalid_voxel_field};
        error:function_clause -> {error,invalid_voxel_field}
    end.
value({ok,V}) -> V;
value({error,R}) -> throw({voxel_error,R}).
chunk_coordinate({chunk_v1,X,Y,Z}) -> lists:all(fun is_integer/1,[X,Y,Z]);
chunk_coordinate(_) -> false.
chunk_origin({chunk_v1,X,Y,Z}) -> {X*?CHUNK,Y*?CHUNK,Z*?CHUNK}.
nearby({chunk_v1,X,Y,Z},{chunk_v1,A,B,C}) -> abs(X-A) =< 1 andalso abs(Y-B) =< 1 andalso abs(Z-C) =< 1.
sampling_limits({sampling_limits,A,B,C,D}) -> lists:all(fun allowance/1,[A,B,C,D]);
sampling_limits(_) -> false.
scale_point({X,Y,Z},S) -> {X*S,Y*S,Z*S}.
sample_at(D,M,I) ->
    <<V:8/signed>> = binary:part(D,I,1),
    <<Mat:16>> = binary:part(M,I*2,2), {V,Mat}.
decode_patch(Bin) -> decode_patch(Bin,-1,#{}).
decode_patch(<<>>,_,Acc) -> Acc;
decode_patch(<<I:16,V:8/signed,M:16,Rest/binary>>,Previous,Acc)
  when I > Previous,I < ?CHUNK*?CHUNK*?CHUNK,V rem 2 =/= 0 ->
    decode_patch(Rest,I,Acc#{I => {V,M}});
decode_patch(_,_,_) -> throw({voxel_error,invalid_voxel_patch}).
owner({X,Y,Z}) ->
    {Cx,Cy,Cz} = {floor_div(X,?CHUNK),floor_div(Y,?CHUNK),floor_div(Z,?CHUNK)},
    {{chunk_v1,Cx,Cy,Cz},(Z-Cz*?CHUNK)*?CHUNK*?CHUNK+(Y-Cy*?CHUNK)*?CHUNK+X-Cx*?CHUNK}.
consumers({X,Y,Z}) ->
    [{chunk_v1,A,B,C} || A <- lists:seq(floor_div(X-2,?CHUNK),floor_div(X+1,?CHUNK)),
                         B <- lists:seq(floor_div(Y-2,?CHUNK),floor_div(Y+1,?CHUNK)),
                         C <- lists:seq(floor_div(Z-2,?CHUNK),floor_div(Z+1,?CHUNK))].
valid_brush({dig_sphere,P,R}) -> point(P) andalso is_integer(R) andalso R > 0;
valid_brush({paint_sphere,P,R,M}) -> point(P) andalso is_integer(R) andalso R > 0 andalso material(M);
valid_brush(_) -> false.
brush({dig_sphere,C,R},P,S,{D,M}) ->
    V = quantize(-base({sphere,C,R},P),S), {max(D,V),M};
brush({paint_sphere,{vector,X,Y,Z},R,Mat},{Px,Py,Pz},_,{D,M}) ->
    {D,case squared(Px-X,Py-Y,Pz-Z) =< R*R of true -> Mat; false -> M end}.
quantize(D,S) -> max(-127,min(127,2*floor_div(D*64,S)+1)).

spacing(S) -> is_integer(S) andalso S >= 256 andalso S =< 16#ffffffff andalso S rem 2 =:= 0.
allowance(N) -> is_integer(N) andalso N >= 0.
material(N) -> is_integer(N) andalso N >= 0 andalso N =< 65535.
point({vector,X,Y,Z}) -> lists:all(fun is_integer/1,[X,Y,Z]);
point(_) -> false.
valid_base({plane,H}) -> is_integer(H);
valid_base({sphere,P,R}) -> point(P) andalso is_integer(R) andalso R > 0;
valid_base(_) -> false.
valid_layer({Kind,Amp,Scale,Salt}) when Kind =:= relief; Kind =:= volume ->
    is_integer(Amp) andalso Amp >= 0 andalso valid_noise(Scale,Salt);
valid_layer({biome_relief,ClimateScale,ClimateSalt,ReliefScale,ReliefSalt,Bands}) ->
    valid_noise(ClimateScale,ClimateSalt) andalso valid_noise(ReliefScale,ReliefSalt)
        andalso is_list(Bands) andalso Bands =/= [] andalso valid_biomes(Bands,-?Q-1);
valid_layer({caves,Scale,Salt,Width,Depth}) ->
    valid_noise(Scale,Salt) andalso is_integer(Width) andalso Width > 0 andalso Width < ?Q
        andalso is_integer(Depth) andalso Depth >= 0;
valid_layer({carve_sphere,P,R}) -> point(P) andalso is_integer(R) andalso R > 0;
valid_layer({carve_tunnel,A,B,R}) -> point(A) andalso point(B) andalso A =/= B
    andalso is_integer(R) andalso R > 0;
valid_layer({material_below,H,M}) -> is_integer(H) andalso material(M);
valid_layer({clip_box,{vector,X0,Y0,Z0},{vector,X1,Y1,Z1}}) ->
    lists:all(fun is_integer/1,[X0,Y0,Z0,X1,Y1,Z1]) andalso X0 < X1 andalso Y0 < Y1 andalso Z0 < Z1;
valid_layer(_) -> false.
valid_noise(Scale,Salt) -> is_integer(Scale) andalso Scale > 0
    andalso is_integer(Salt) andalso Salt >= 0 andalso Salt < (1 bsl 64).
valid_biomes([],_) -> true;
valid_biomes([{biome,Centre,Height,Amplitude,Top,Soil,Depth}|Rest],Previous) ->
    is_integer(Centre) andalso Centre > Previous andalso Centre >= -?Q andalso Centre =< ?Q
        andalso is_integer(Height) andalso is_integer(Amplitude) andalso Amplitude >= 0
        andalso material(Top) andalso material(Soil) andalso is_integer(Depth) andalso Depth >= 0
        andalso valid_biomes(Rest,Centre);
valid_biomes(_,_) -> false.
operator_cost({biome_relief,_,_,_,_,Bands}) -> 1+length(Bands);
operator_cost(_) -> 1.
hash_cost({Kind,_,_,_}) when Kind =:= relief; Kind =:= volume -> 8;
hash_cost({biome_relief,_,_,_,_,_}) -> 16;
hash_cost({caves,_,_,_,_}) -> 8;
hash_cost(_) -> 0.
charge(_,Actual,Limit) when Actual =< Limit -> ok;
charge(Resource,Actual,Limit) -> throw({voxel_allowance,Resource,Actual,Limit}).

samples(I,Count,_,_,_,_,_,_,Cache,D,M) when I =:= Count -> {D,M,Cache};
samples(I,Count,{Nx,Ny}=Dims,{X,Y,Z}=Origin,Seed,S,Ops,Material,Cache0,D,M) ->
    P = {(X+I rem Nx)*S,(Y+(I div Nx) rem Ny)*S,(Z+I div (Nx*Ny))*S},
    [Base | Layers] = Ops,
    {Field,Mat,Cache} = lists:foldl(fun(Op,State) -> layer(Op,P,Seed,State) end,
                                   {base(Base,P),Material,Cache0},Layers),
    Q = quantize(Field,S),
    samples(I+1,Count,Dims,Origin,Seed,S,Ops,Material,Cache,
            [Q band 255 | D],[<<Mat:16/unsigned-big>> | M]).

base({plane,H},{_,Y,_}) -> Y-H;
base({sphere,{vector,X,Y,Z},R},{Px,Py,Pz}) ->
    isqrt(squared(Px-X,Py-Y,Pz-Z))-R.
layer({Kind,Amp,Scale,Salt},{X,Y,Z},Seed,{D,Mat,Cache0})
  when Kind =:= relief; Kind =:= volume ->
    Position = case Kind of relief -> {X,0,Z}; volume -> {X,Y,Z} end,
    {Noise,Cache} = noise(Position,Scale,{Seed,Salt},Cache0),
    {D-floor_div(Amp*Noise,?Q),Mat,Cache};
layer({biome_relief,CS,CK,RS,RK,Bands},{X,_,Z},Seed,{D,_,Cache0}) ->
    {Climate,Cache1} = noise({X,0,Z},CS,{Seed,CK},Cache0),
    {Relief,Cache} = noise({X,0,Z},RS,{Seed,RK},Cache1),
    {Height,Amp,Top,Soil,Depth} = biome(Climate,Bands),
    Surface = D-Height-floor_div(Amp*Relief,?Q),
    {Surface,case Surface < -Depth of true -> Soil; false -> Top end,Cache};
layer({caves,Scale,Salt,Width,Depth},P,Seed,{D,Mat,Cache0}) ->
    {Noise,Cache} = noise(P,Scale,{Seed,Salt},Cache0),
    {max(D,min(-D-Depth,floor_div((Width-abs(Noise))*Scale,?Q))),Mat,Cache};
layer({carve_sphere,Centre,R},P,_,{D,Mat,Cache}) ->
    {max(D,-base({sphere,Centre,R},P)),Mat,Cache};
layer({carve_tunnel,{vector,Ax,Ay,Az},{vector,Bx,By,Bz},R},{X,Y,Z},_,{D,Mat,Cache}) ->
    {Ux,Uy,Uz} = {Bx-Ax,By-Ay,Bz-Az},
    {Vx,Vy,Vz} = {X-Ax,Y-Ay,Z-Az},
    Length = squared(Ux,Uy,Uz), Dot = Vx*Ux+Vy*Uy+Vz*Uz,
    Distance2 = if Dot =< 0 -> squared(Vx,Vy,Vz);
                   Dot >= Length -> squared(X-Bx,Y-By,Z-Bz);
                   true -> (squared(Vx,Vy,Vz)*Length-Dot*Dot) div Length end,
    {max(D,R-isqrt(Distance2)),Mat,Cache};
layer({material_below,H,M},{_,Y,_},_,{D,Mat,Cache}) ->
    {D,case Y < H of true -> M; false -> Mat end,Cache};
layer({clip_box,{vector,X0,Y0,Z0},{vector,X1,Y1,Z1}},{X,Y,Z},_,{D,Mat,Cache}) ->
    {lists:max([D,X0-X,X-X1,Y0-Y,Y-Y1,Z0-Z,Z-Z1]),Mat,Cache}.

%% Climate interpolates continuous terrain parameters; categorical material
%% identity comes from the nearest authored band, with lower-band ties.
biome(_, [{biome,_,H,A,T,S,D}]) -> {H,A,T,S,D};
biome(N,[{biome,C,H,A,T,S,D}|_]) when N =< C -> {H,A,T,S,D};
biome(N,[{biome,C0,H0,A0,T0,S0,D0},B = {biome,C1,H1,A1,T1,S1,D1}|Rest]) ->
    case N > C1 of
        true -> biome(N,[B|Rest]);
        false ->
            Height = H0+floor_div((H1-H0)*(N-C0),C1-C0),
            Amp = A0+floor_div((A1-A0)*(N-C0),C1-C0),
            Depth = D0+floor_div((D1-D0)*(N-C0),C1-C0),
            {Top,Soil} = case 2*N =< C0+C1 of true -> {T0,S0}; false -> {T1,S1} end,
            {Height,Amp,Top,Soil,Depth}
    end.

noise({X,Y,Z},Scale,Key,Cache0) ->
    {A,B,C} = {floor_div(X,Scale),floor_div(Y,Scale),floor_div(Z,Scale)},
    {Tx,Ty,Tz} = {smooth((X-A*Scale)*?Q div Scale),
                  smooth((Y-B*Scale)*?Q div Scale),smooth((Z-C*Scale)*?Q div Scale)},
    {Values,Cache} = lists:mapfoldl(fun({Dx,Dy,Dz},Acc) ->
        hash({Key,A+Dx,B+Dy,C+Dz},Acc) end, Cache0,
        [{0,0,0},{1,0,0},{0,1,0},{1,1,0},{0,0,1},{1,0,1},{0,1,1},{1,1,1}]),
    [A0,A1,B0,B1,C0,C1,D0,D1] = Values,
    {lerp(lerp(lerp(A0,A1,Tx),lerp(B0,B1,Tx),Ty),
          lerp(lerp(C0,C1,Tx),lerp(D0,D1,Tx),Ty),Tz),Cache}.
hash({{Seed,Salt},X,Y,Z}=Key,Cache) ->
    case maps:find(Key,Cache) of
        {ok,V} -> {V,Cache};
        error ->
            <<N:16/unsigned-big,_/binary>> = crypto:hash(sha256,
                [<<"quod-voxel-noise-v1",Seed:64/unsigned-big,Salt:64/unsigned-big>>,
                 coordinate(X),coordinate(Y),coordinate(Z)]),
            V = 2*N-65535,
            {V,Cache#{Key => V}}
    end.
coordinate(N) ->
    Bytes = binary:encode_unsigned(abs(N)),
    [<<(case N < 0 of true -> 1; false -> 0 end):8,(byte_size(Bytes)):32/unsigned-big>>,Bytes].
smooth(T) -> T*T*(3*?Q-2*T) div (?Q*?Q).
lerp(A,B,T) -> A+floor_div((B-A)*T,?Q).
floor_div(N,D) -> Q = N div D, case N rem D < 0 of true -> Q-1; false -> Q end.
squared(X,Y,Z) -> X*X+Y*Y+Z*Z.
isqrt(0) -> 0;
isqrt(N) -> isqrt(N,N).
isqrt(N,X) -> Y = (X+N div X) div 2, case Y < X of true -> isqrt(N,Y); false -> X end.
