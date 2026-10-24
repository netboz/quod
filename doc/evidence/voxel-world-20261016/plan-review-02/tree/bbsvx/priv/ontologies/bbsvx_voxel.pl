%% =============================================================================
%% BBSvx Voxel World Generation (Pure Prolog)
%%
%% Squirrel3 hash-based pseudo-random terrain generation for voxel worlds.
%% Uses fixed-point integer arithmetic with smoothstep interpolation for
%% natural-looking terrain. All computation is deterministic and on-demand.
%%
%% Terrain height centered around Y=3, range roughly -12 to +18.
%% 4-octave FBM (Fractional Brownian Motion) value noise.
%%
%% Class: voxel_world
%%   Instantiate to initialize a voxel world with a seed.
%%   Then call generate_chunk(Ox, Oz, Size, Seed, SeaLevel) to populate.
%%   Blocks stored as block(X, Y, Z, Type) facts.
%%
%% Usage:
%%   1. assertz(instance_of(physical_space, self))
%%   2. assertz(instance_of(voxel_world, self))
%%   3. generate_chunk(0, 0, 16, 42, 0) — generates 16x16 chunk
%%      (internally calls 'bbsvx:voxel'::generate_terrain_data via scope_prove)
%% =============================================================================

%% =============================================================================
%% Voxel World Class
%% =============================================================================

isa(voxel_world, thing).
have_attribute(voxel_world, seed).
have_attribute(voxel_world, chunk_size).

%% Effect: when voxel_world is instantiated, signal initialization.
%% The init_voxel_world effect is a client-side marker — the client
%% recognizes the voxel_world class and activates voxel rendering mode.
effect(voxel_world, create_instance, Instance,
       init_voxel_world(Instance, Seed, ChunkSize)) :-
    (attribute(Instance, seed, Seed) -> true ; Seed = 42),
    (attribute(Instance, chunk_size, ChunkSize) -> true ; ChunkSize = 16).

%% =============================================================================
%% Utility: between/3
%% Standard between/3 (not built into erlog)
%% =============================================================================

between(Low, High, Low) :- Low =< High.
between(Low, High, X) :-
    Low < High,
    Low1 is Low + 1,
    between(Low1, High, X).

%% =============================================================================
%% Bitwise XOR Helper
%% Erlog has \/ (bor), /\ (band), \ (bnot) but no native xor.
%% XOR(A,B) = (A | B) & ~(A & B), masked to 32 bits.
%% =============================================================================

bit_xor(A, B, Result) :-
    Result is ((A \/ B) /\ (\ (A /\ B))) /\ 4294967295.

%% =============================================================================
%% Squirrel3 Hash Function
%% High-quality deterministic hash from integer position + seed.
%% Returns value in [0, 4294967295] (32-bit unsigned range).
%% Every multiply/add is masked to 32 bits to prevent bignum drift.
%% =============================================================================

squirrel3(Pos, Seed, Result) :-
    P0 is (Pos /\ 4294967295),
    M0 is (P0 * 3039420493) /\ 4294967295,
    M1 is (M0 + Seed) /\ 4294967295,
    bit_xor(M1, M1 >> 8, M2),
    M3 is (M2 + 1758765476) /\ 4294967295,
    Shifted4 is (M3 << 8) /\ 4294967295,
    bit_xor(M3, Shifted4, M4),
    M5 is (M4 * 458313961) /\ 4294967295,
    bit_xor(M5, M5 >> 8, Result).

%% =============================================================================
%% 2D Hash
%% Combines X and Z into a single integer position for Squirrel3.
%% Uses a large prime multiplier on Z for spatial decorrelation.
%% =============================================================================

hash2d(X, Z, Seed, Result) :-
    Pos is (X + Z * 198491317) /\ 4294967295,
    squirrel3(Pos, Seed, Result).

%% =============================================================================
%% Fixed-Point Arithmetic (SCALE = 1024)
%%
%% smoothstep(T, S): cubic smoothstep, T in [0,1024], S in [0,1024]
%%   S = 3*T^2 - 2*T^3 (in fixed-point)
%%
%% lerp(A, B, T, R): linear interpolation, T in [0,1024]
%%   R = A + (B - A) * T / 1024
%% =============================================================================

smoothstep(T, S) :-
    T2 is (T * T) // 1024,
    T3 is (T2 * T) // 1024,
    S is 3 * T2 - 2 * T3.

lerp(A, B, T, R) :-
    R is A + ((B - A) * T) // 1024.

%% =============================================================================
%% Positive Modulo
%% Handles negative coordinates correctly: ((X mod M) + M) mod M
%% =============================================================================

pos_mod(X, M, R) :-
    R is ((X mod M) + M) mod M.

%% =============================================================================
%% Value Noise
%% Grid-based noise with bilinear interpolation and smoothstep.
%%
%% value_noise(X, Z, Seed, GridScale, Value)
%%   Returns Value in [0, 1024] representing smooth noise at (X, Z).
%%
%% Algorithm:
%%   1. Find grid cell containing (X, Z)
%%   2. Hash at 4 corners -> values in [0, 1024]
%%   3. Compute fractional position within cell -> [0, 1024] fixed-point
%%   4. Smoothstep the fractional values for smooth transitions
%%   5. Bilinear interpolation of corner values
%% =============================================================================

value_noise(X, Z, Seed, GridScale, Value) :-
    %% Grid cell coordinates (floor division for negatives)
    GX0 is X // GridScale,
    GZ0 is Z // GridScale,
    %% Correct floor for negative coordinates:
    %% If X is negative and not evenly divisible, // rounds toward zero
    %% but we need floor (round toward negative infinity)
    (X < 0, X mod GridScale =\= 0 -> GXF is GX0 - 1 ; GXF = GX0),
    (Z < 0, Z mod GridScale =\= 0 -> GZF is GZ0 - 1 ; GZF = GZ0),
    %% Fractional position within cell [0, GridScale-1] -> [0, 1024]
    pos_mod(X, GridScale, FracXRaw),
    pos_mod(Z, GridScale, FracZRaw),
    FracX is (FracXRaw * 1024) // GridScale,
    FracZ is (FracZRaw * 1024) // GridScale,
    %% Hash at four grid corners, reduce to [0, 1024]
    GX1 is GXF + 1,
    GZ1 is GZF + 1,
    hash2d(GXF, GZF, Seed, H00),
    hash2d(GX1, GZF, Seed, H10),
    hash2d(GXF, GZ1, Seed, H01),
    hash2d(GX1, GZ1, Seed, H11),
    C00 is H00 mod 1025,
    C10 is H10 mod 1025,
    C01 is H01 mod 1025,
    C11 is H11 mod 1025,
    %% Smoothstep the fractional positions
    smoothstep(FracX, SX),
    smoothstep(FracZ, SZ),
    %% Bilinear interpolation
    lerp(C00, C10, SX, NX0),
    lerp(C01, C11, SX, NX1),
    lerp(NX0, NX1, SZ, Value).

%% =============================================================================
%% Terrain Height (4-octave FBM)
%%
%% terrain_height(X, Z, Seed, Height)
%%   Returns integer Height, roughly in range [-5, +10].
%%
%% Octaves:
%%   0: grid=32, amplitude=8  (large rolling hills)
%%   1: grid=16, amplitude=4  (medium bumps)
%%   2: grid=8,  amplitude=2  (small detail)
%%   3: grid=4,  amplitude=1  (fine grain)
%%
%% Each octave's noise [0,1024] is scaled to [-Amplitude, +Amplitude]
%% by: (N * 2 * Amplitude) // 1024 - Amplitude
%%
%% Base height = 3 so terrain surface mostly sits above sea level (Y=0).
%% Max total variation = +/- 15 blocks.
%% =============================================================================

terrain_height(X, Z, Seed, Height) :-
    %% Octave 0: large hills
    value_noise(X, Z, Seed, 32, N0),
    H0 is (N0 * 16) // 1024 - 8,
    %% Octave 1: medium bumps
    Seed1 is (Seed + 31337) /\ 4294967295,
    value_noise(X, Z, Seed1, 16, N1),
    H1 is (N1 * 8) // 1024 - 4,
    %% Octave 2: small detail
    Seed2 is (Seed + 62674) /\ 4294967295,
    value_noise(X, Z, Seed2, 8, N2),
    H2 is (N2 * 4) // 1024 - 2,
    %% Octave 3: fine grain
    Seed3 is (Seed + 94011) /\ 4294967295,
    value_noise(X, Z, Seed3, 4, N3),
    H3 is (N3 * 2) // 1024 - 1,
    %% Sum with base height
    Height is 3 + H0 + H1 + H2 + H3.

%% =============================================================================
%% Biome System
%% Uses hash at large grid scale (64) for biome selection.
%% Determines surface block type.
%% =============================================================================

biome_at(X, Z, Seed, Biome) :-
    BSeed is (Seed + 104729) /\ 4294967295,
    %% Large-scale noise for biome regions
    value_noise(X, Z, BSeed, 64, BiomeVal),
    classify_biome(BiomeVal, Biome).

%% Classify biome from noise value [0, 1024]
classify_biome(V, desert) :- V >= 820, !.
classify_biome(V, snow) :- V < 200, !.
classify_biome(_, plains).

%% =============================================================================
%% Block Selection
%% Given world coordinates and seed, determine block type.
%%
%% Layers:
%%   Y > terrain_height        -> air
%%   Y =< -15                  -> bedrock
%%   Y == terrain_height       -> surface (biome-dependent)
%%   depth 1-3                 -> dirt (or sand in desert)
%%   depth > 3                 -> stone (with ore checks)
%% =============================================================================

%% Air above terrain
block_at(X, Y, Z, Seed, air) :-
    terrain_height(X, Z, Seed, H),
    Y > H, !.

%% Bedrock floor
block_at(_, Y, _, _, bedrock) :-
    Y =< -15, !.

%% Solid blocks: surface + subsurface + deep
block_at(X, Y, Z, Seed, Block) :-
    terrain_height(X, Z, Seed, H),
    Y =< H,
    Depth is H - Y,
    biome_at(X, Z, Seed, Biome),
    biome_block(Biome, Depth, H, X, Y, Z, Seed, Block).

%% =============================================================================
%% Biome Block Selection
%% biome_block(Biome, Depth, TerrainHeight, X, Y, Z, Seed, Block)
%% =============================================================================

%% Surface layer (depth 0)
%% Below sea level (Y =< 0): sand regardless of biome
biome_block(_, 0, H, _, _, _, _, sand) :- H =< 0, !.
%% Biome-specific surface above sea level
biome_block(plains, 0, _, _, _, _, _, grass) :- !.
biome_block(desert, 0, _, _, _, _, _, sand) :- !.
biome_block(snow, 0, _, _, _, _, _, snow_block) :- !.

%% Subsurface (depth 1-3)
biome_block(desert, D, _, _, _, _, _, sand) :- D =< 3, !.
biome_block(_, D, _, _, _, _, _, dirt) :- D =< 3, !.

%% Deep layer (depth > 3): stone with occasional ores
biome_block(_, Depth, _, X, Y, Z, Seed, Block) :-
    Depth > 3,
    ore_check(X, Y, Z, Seed, Block).

%% =============================================================================
%% Ore Generation
%% Uses 3D hash for sparse ore placement in stone layer.
%% =============================================================================

%% 3D hash for ore checks
hash3d(X, Y, Z, Seed, Result) :-
    Pos is (X + Y * 374761393 + Z * 198491317) /\ 4294967295,
    squirrel3(Pos, Seed, Result).

ore_check(X, Y, Z, Seed, coal_ore) :-
    OreSeed is (Seed + 31337) /\ 4294967295,
    hash3d(X, Y, Z, OreSeed, H),
    H mod 100 < 5, !.

ore_check(X, Y, Z, Seed, iron_ore) :-
    Y < -5,
    OreSeed is (Seed + 65537) /\ 4294967295,
    hash3d(X, Y, Z, OreSeed, H),
    H mod 100 < 3, !.

ore_check(_, _, _, _, stone).

%% =============================================================================
%% Block Properties
%% Color and material properties for rendering.
%% block_color(BlockType, R, G, B) - RGB 0.0-1.0
%% =============================================================================

%% Block textures (BabylonJS playground CDN)
%% Blocks with textures get texture_url attribute; others fall back to block_color.
block_texture(grass, 'https://playground.babylonjs.com/textures/grass.png').
block_texture(dirt,  'https://playground.babylonjs.com/textures/ground.jpg').
block_texture(stone, 'https://playground.babylonjs.com/textures/rock.png').
block_texture(sand,  'https://playground.babylonjs.com/textures/sand.jpg').

block_color(grass,      0.2, 0.7, 0.2).
block_color(dirt,       0.5, 0.35, 0.2).
block_color(stone,      0.5, 0.5, 0.5).
block_color(sand,       0.9, 0.85, 0.6).
block_color(snow_block, 0.95, 0.95, 0.98).
block_color(bedrock,    0.15, 0.15, 0.15).
block_color(coal_ore,   0.25, 0.25, 0.25).
block_color(iron_ore,   0.6, 0.5, 0.4).
block_color(water,      0.2, 0.4, 0.8).
block_color(log,        0.4, 0.25, 0.1).
block_color(leaves,     0.1, 0.5, 0.1).
block_color(air,        1.0, 1.0, 1.0).

%% =============================================================================
%% Tree Placement
%% Sparse trees on grass surfaces using hash-based probability.
%% =============================================================================

has_tree(X, Z, Seed) :-
    TreeSeed is (Seed + 99991) /\ 4294967295,
    hash2d(X, Z, TreeSeed, H),
    H mod 100 < 4.

%% tree_block(X, Y, Z, TreeBaseX, TreeBaseZ, TreeBaseY, Block)
%% Trunk: 4 blocks high at tree base position
tree_block(X, Y, Z, TX, TZ, TY, log) :-
    X =:= TX, Z =:= TZ,
    Y >= TY, DY is Y - TY, DY =< 3, !.

%% Leaves: 3x3x2 canopy at top of trunk
tree_block(X, Y, Z, TX, TZ, TY, leaves) :-
    TopY is TY + 4,
    (Y =:= TopY ; Y =:= TopY + 1),
    DX is abs(X - TX), DX =< 1,
    DZ is abs(Z - TZ), DZ =< 1.

%% =============================================================================
%% Chunk Generation Helper
%% surface_block generates visible blocks for a chunk region.
%% Only emits surface + 3 subsurface layers for efficiency.
%% =============================================================================

surface_block(CX, CZ, Size, Seed, X, Y, Z, Block) :-
    MaxX is CX + Size - 1,
    MaxZ is CZ + Size - 1,
    between(CX, MaxX, X),
    between(CZ, MaxZ, Z),
    terrain_height(X, Z, Seed, H),
    MinY is H - 3,
    between(MinY, H, Y),
    block_at(X, Y, Z, Seed, Block),
    Block \= air.

%% =============================================================================
%% Batch Terrain Generation (called via :: from generate_chunk external pred)
%%
%% generate_terrain_data(Ox, Oz, Size, Seed, Blocks, Surfaces)
%%   Returns all blocks and surface positions for a chunk region.
%%   Blocks: list of b(X, Y, Z, Type) — non-air blocks in the chunk
%%   Surfaces: list of s(X, H, Z) — surface height at each column
%% =============================================================================

generate_terrain_data(Ox, Oz, Size, Seed, Blocks, Surfaces) :-
    MaxX is Ox + Size - 1,
    MaxZ is Oz + Size - 1,
    %% Compute heights once per column
    findall(s(X, H, Z),
        (between(Ox, MaxX, X),
         between(Oz, MaxZ, Z),
         terrain_height(X, Z, Seed, H)),
        Surfaces),
    %% Derive blocks from pre-computed surface heights
    findall(b(X, Y, Z, Type),
        (member(s(X, H, Z), Surfaces),
         MinY is H - 3,
         between(MinY, H, Y),
         block_at(X, Y, Z, Seed, Type),
         Type \= air),
        Blocks).
