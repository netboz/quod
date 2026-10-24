import { Scene } from '@babylonjs/core';
import { CHUNK_SIZE, MAX_CHUNK_UPLOADS_PER_FRAME } from '../core/constants';
import { Chunk } from './Chunk';
import { WorkerPool } from './WorkerPool';
import type { MeshResult } from './WorkerPool';
import { ChunkMeshUploader } from './ChunkMeshUploader';
import { MaterialCache } from '../rendering/MaterialCache';
import { chunkKey, worldToChunk, chunkToWorld, worldToLocal } from '../utils/spatial';
import type { ChunkKey, BlockPalette, BlockPaletteEntry, VoxelId } from './types';

export class ChunkManager {
  /** Well-known block type colors (Minecraft-style defaults) */
  private static readonly DEFAULT_COLORS: Record<string, [number, number, number]> = {
    // Terrain
    stone:       [0.50, 0.50, 0.50],
    dirt:        [0.55, 0.36, 0.24],
    grass:       [0.30, 0.65, 0.20],
    sand:        [0.85, 0.80, 0.55],
    snow_block:  [0.92, 0.94, 0.96],
    bedrock:     [0.20, 0.20, 0.20],
    cobblestone: [0.45, 0.45, 0.42],
    // Ores
    coal_ore:    [0.25, 0.25, 0.25],
    iron_ore:    [0.60, 0.50, 0.40],
    gold_ore:    [0.85, 0.75, 0.30],
    // Vegetation
    log:         [0.45, 0.30, 0.15],
    leaves:      [0.20, 0.55, 0.15],
    // Liquid
    water:       [0.20, 0.40, 0.80],
  };

  private chunks = new Map<ChunkKey, Chunk>();
  private dirtyChunks = new Set<ChunkKey>();
  private inFlightGenerations = new Map<ChunkKey, number>();

  private workerPool: WorkerPool;
  private meshUploader: ChunkMeshUploader;
  private materialCache: MaterialCache;
  private _scene: Scene;

  /** Block type name -> VoxelId mapping */
  private typeRegistry = new Map<string, VoxelId>();
  private nextTypeId: VoxelId = 1; // 0 = air

  /** Palette for mesher color lookup */
  palette: BlockPalette = new Map();

  constructor(
    scene: Scene,
    workerPool: WorkerPool,
    meshUploader: ChunkMeshUploader,
    materialCache: MaterialCache,
  ) {
    this._scene = scene;
    this.workerPool = workerPool;
    this.meshUploader = meshUploader;
    this.materialCache = materialCache;

    // Register air
    this.palette.set(0, { id: 0, name: 'air', color: [0, 0, 0] });
  }

  /** Resolve a block type name to a VoxelId, registering new types as needed */
  resolveType(typeName: string): VoxelId {
    let id = this.typeRegistry.get(typeName);
    if (id !== undefined) return id;
    id = this.nextTypeId++;
    this.typeRegistry.set(typeName, id);
    this.palette.set(id, {
      id,
      name: typeName,
      color: ChunkManager.DEFAULT_COLORS[typeName] ?? this._hashColor(typeName),
    });
    return id;
  }

  /** Set a block at world position. Creates chunk if needed. */
  setBlock(_namespace: string, wx: number, wy: number, wz: number, typeName: string): void {
    const { cx, cy, cz } = worldToChunk(wx, wy, wz);
    const key = chunkKey(cx, cy, cz);

    let chunk = this.chunks.get(key);
    if (!chunk) {
      chunk = new Chunk(cx, cy, cz);
      this.chunks.set(key, chunk);
    }

    const [lx, ly, lz] = worldToLocal(wx, wy, wz);
    const typeId = this.resolveType(typeName);
    chunk.set(lx, ly, lz, typeId);
    this.dirtyChunks.add(key);
  }

  /** Remove a block at world position (set to air). */
  removeBlock(_namespace: string, wx: number, wy: number, wz: number): void {
    const { cx, cy, cz } = worldToChunk(wx, wy, wz);
    const key = chunkKey(cx, cy, cz);
    const chunk = this.chunks.get(key);
    if (!chunk) return;

    const [lx, ly, lz] = worldToLocal(wx, wy, wz);
    chunk.set(lx, ly, lz, 0);
    this.dirtyChunks.add(key);
  }

  /** Clear all chunks for a namespace. For now clears all (single-namespace). */
  clearNamespace(_namespace: string): void {
    for (const chunk of this.chunks.values()) {
      chunk.clear();
    }
    this.meshUploader.clear();
    this.dirtyChunks.clear();
    this.chunks.clear();
  }

  /** Process dirty chunks -- call this each frame or on a timer */
  processDirtyChunks(maxPerFrame: number = MAX_CHUNK_UPLOADS_PER_FRAME): void {
    if (this.dirtyChunks.size === 0) return;

    const toProcess = Array.from(this.dirtyChunks).slice(0, maxPerFrame);

    for (const key of toProcess) {
      this.dirtyChunks.delete(key);
      const chunk = this.chunks.get(key);
      if (!chunk || !chunk.dirty) continue;

      chunk.dirty = false;
      const gen = chunk.generation;
      this.inFlightGenerations.set(key, gen);

      const paletteArray = this._buildPaletteArray();
      const voxelBuffer = chunk.toTransferable();
      const [wx, wy, wz] = chunkToWorld(chunk.coord);

      this.workerPool
        .submit(key, voxelBuffer, CHUNK_SIZE, paletteArray, wx, wy, wz)
        .then((result) => this._onMeshResult(result, gen))
        .catch((err) => {
          console.warn('[ChunkManager] Meshing failed for', key, err);
          this.inFlightGenerations.delete(key);
          this.dirtyChunks.add(key);  // Re-queue for retry
        });
    }
  }

  private _onMeshResult(result: MeshResult, expectedGeneration: number): void {
    const { chunkKey: key, meshData } = result;

    // Check if this result is stale (in-flight tracking)
    const sentGen = this.inFlightGenerations.get(key);
    if (sentGen !== expectedGeneration) {
      // Chunk was modified while meshing -- discard stale result
      return;
    }
    this.inFlightGenerations.delete(key);

    const chunk = this.chunks.get(key);
    if (!chunk) {
      this.meshUploader.remove(key);
      return;
    }

    // Discard if chunk was modified since this mesh was requested
    if (chunk.generation !== expectedGeneration) {
      this.dirtyChunks.add(key);  // Re-queue for meshing
      return;
    }

    if (meshData) {
      const [wx, wy, wz] = chunkToWorld(chunk.coord);
      const mesh = this.meshUploader.upload(key, meshData, wx, wy, wz);
      mesh.material = this.materialCache.chunkOpaque;
      mesh.receiveShadows = true;
    } else {
      // Empty chunk -- remove mesh if it exists
      this.meshUploader.remove(key);
    }
  }

  private _buildPaletteArray(): BlockPaletteEntry[] {
    const arr: BlockPaletteEntry[] = [];
    for (const [id, entry] of this.palette) {
      arr[id] = entry;
    }
    return arr;
  }

  /** Generate a deterministic color from a type name */
  private _hashColor(name: string): [number, number, number] {
    let hash = 0;
    for (let i = 0; i < name.length; i++) {
      hash = ((hash << 5) - hash + name.charCodeAt(i)) | 0;
    }
    const r = ((hash >> 16) & 0xff) / 255;
    const g = ((hash >> 8) & 0xff) / 255;
    const b = (hash & 0xff) / 255;
    return [Math.max(0.2, r), Math.max(0.2, g), Math.max(0.2, b)];
  }

  get scene(): Scene {
    return this._scene;
  }

  get chunkCount(): number {
    return this.chunks.size;
  }
  get dirtyCount(): number {
    return this.dirtyChunks.size;
  }

  /** Remove a chunk entirely (for unloading distant terrain). */
  removeChunk(key: ChunkKey): void {
    this.chunks.delete(key);
    this.dirtyChunks.delete(key);
    this.inFlightGenerations.delete(key);
    this.meshUploader.remove(key);
  }

  /** Update palette color for a block type from ontology block_color facts. */
  updatePaletteColor(typeName: string, r: number, g: number, b: number): void {
    const id = this.resolveType(typeName);
    const entry = this.palette.get(id);
    if (entry) entry.color = [r, g, b];
  }

  /** Update palette texture URL from ontology block_texture facts. */
  updatePaletteTexture(typeName: string, url: string): void {
    const id = this.resolveType(typeName);
    const entry = this.palette.get(id);
    if (entry) entry.textureUrl = url;
  }

  dispose(): void {
    this.meshUploader.dispose();
    this.workerPool.dispose();
    this.chunks.clear();
    this.dirtyChunks.clear();
  }
}
