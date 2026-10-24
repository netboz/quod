import type { ProveClient } from '../network/ProveClient';
import type { ChunkManager } from './ChunkManager';
import type { SceneManager } from '../core/SceneManager';
import type { TerrainBlock } from './TerrainGenerator';
import type { TerrainRequest, TerrainResponse } from './types';
import {
  CHUNK_SIZE,
  RENDER_DISTANCE_CHUNKS,
  UNLOAD_DISTANCE_CHUNKS,
  MAX_CONCURRENT_TERRAIN_GENS,
  MAX_CONCURRENT_COLLIDER_REQUESTS,
  CHUNK_LOADER_POLL_MS,
  DEFAULT_SEA_LEVEL,
} from '../core/constants';

export interface ChunkLoaderConfig {
  renderDistance: number;
  unloadDistance: number;
  /** Max concurrent terrain generation requests in-flight to the worker. */
  maxConcurrentGens: number;
  pollIntervalMs: number;
  seed: number;
  seaLevel: number;
}

/** Column key format: "cx:cz" (colon-separated to distinguish from 3D chunk keys) */
type ColumnKey = string;

type ColumnState = 'pending' | 'loading' | 'loaded' | 'failed';

/** Max consecutive failures before a column is marked 'failed'.
 *  Failed columns are retried when the camera re-enters their area. */
const MAX_RETRIES = 3;

/**
 * Tracks camera position and generates terrain chunks via a dedicated terrain worker.
 * Terrain blocks go directly into ChunkManager (no WebSocket round-trip).
 * Physics colliders are requested from the server asynchronously after local generation.
 */
export class ChunkLoader {
  private config: ChunkLoaderConfig;
  private proveClient: ProveClient;
  private chunkManager: ChunkManager;
  private sceneManager: SceneManager;
  private namespace: string;

  private columnStates = new Map<ColumnKey, ColumnState>();
  private retryCount = new Map<ColumnKey, number>();
  private inFlightCount = 0;
  private colliderInFlightCount = 0;
  private loadQueue: ColumnKey[] = [];
  private colliderQueue: Array<{ offsetX: number; offsetZ: number; key: ColumnKey }> = [];

  /** Epoch counter — incremented on reset() to invalidate in-flight requests. */
  private epoch = 0;

  /** Terrain worker — runs PrologTerrainGenerator in a dedicated thread. */
  private readonly _terrainWorker: Worker;
  /** Pending terrain Promises keyed by chunkKey (column key "cx:cz"). */
  private readonly _pendingTerrain = new Map<
    string,
    { resolve: (b: TerrainBlock[]) => void; reject: (e: unknown) => void }
  >();

  /** Disables all new collider requests once the first one fails (permanent for this namespace). */
  private _collidersDisabled = false;
  /** AbortController shared across all in-flight collider requests — aborted on first failure. */
  private _colliderAbort = new AbortController();

  private lastCameraCx = NaN;
  private lastCameraCz = NaN;
  private pollTimer: ReturnType<typeof setInterval> | null = null;
  private disposed = false;

  constructor(
    proveClient: ProveClient,
    chunkManager: ChunkManager,
    sceneManager: SceneManager,
    namespace: string,
    config?: Partial<ChunkLoaderConfig>,
  ) {
    this.proveClient = proveClient;
    this.chunkManager = chunkManager;
    this.sceneManager = sceneManager;
    this.namespace = namespace;
    this.config = {
      renderDistance: config?.renderDistance ?? RENDER_DISTANCE_CHUNKS,
      unloadDistance: config?.unloadDistance ?? UNLOAD_DISTANCE_CHUNKS,
      maxConcurrentGens: config?.maxConcurrentGens ?? MAX_CONCURRENT_TERRAIN_GENS,
      pollIntervalMs: config?.pollIntervalMs ?? CHUNK_LOADER_POLL_MS,
      seed: config?.seed ?? Math.floor(Math.random() * 2 ** 31),
      seaLevel: config?.seaLevel ?? DEFAULT_SEA_LEVEL,
    };

    this._terrainWorker = new Worker(
      new URL('./terrain.worker.ts', import.meta.url),
      { type: 'module' },
    );
    this._terrainWorker.onmessage = (e: MessageEvent<TerrainResponse>) => {
      const { chunkKey, blocks, error } = e.data;
      const pending = this._pendingTerrain.get(chunkKey);
      if (!pending) return; // stale response after reset — discard
      this._pendingTerrain.delete(chunkKey);
      if (error !== undefined) {
        pending.reject(new Error(error));
      } else {
        pending.resolve(blocks as TerrainBlock[]);
      }
    };
  }

  start(): void {
    if (this.pollTimer !== null || this.disposed) return;
    console.log(
      `[ChunkLoader] Starting (seed=${this.config.seed}, render=${this.config.renderDistance})`,
    );
    this.tick();
    this.pollTimer = setInterval(() => this.tick(), this.config.pollIntervalMs);
  }

  stop(): void {
    if (this.pollTimer !== null) {
      clearInterval(this.pollTimer);
      this.pollTimer = null;
    }
  }

  /** Reset all state (e.g., after reconnection). Increments epoch to invalidate in-flight requests. */
  reset(): void {
    this.epoch++;
    this.columnStates.clear();
    this.retryCount.clear();
    this.loadQueue = [];
    this.colliderQueue = [];
    this.inFlightCount = 0;
    this.colliderInFlightCount = 0;
    this.lastCameraCx = NaN;
    this.lastCameraCz = NaN;
    // Reject all pending terrain worker promises to prevent memory leaks from abandoned requests.
    for (const { reject } of this._pendingTerrain.values()) {
      reject(new Error('[ChunkLoader] reset — pending terrain request cancelled'));
    }
    this._pendingTerrain.clear();
    // Do NOT re-enable _collidersDisabled here. prove_timeout for generate_collider/5
    // means the predicate is absent from the namespace — a permanent condition for this
    // namespace, not a transient one. Re-enabling on every full_state would restart the
    // failure storm on each reconnect. A page reload (new ChunkLoader instance) is the
    // correct recovery path if the namespace later gains bbsvx:voxel.
  }

  updateConfig(partial: Partial<ChunkLoaderConfig>): void {
    Object.assign(this.config, partial);
    console.log('[ChunkLoader] Config updated:', partial);
  }

  dispose(): void {
    this.disposed = true;
    this.stop();
    this.columnStates.clear();
    this.retryCount.clear();
    this.loadQueue = [];
    // Reject all pending terrain promises before terminating worker.
    for (const { reject } of this._pendingTerrain.values()) {
      reject(new Error('[ChunkLoader] disposed'));
    }
    this._pendingTerrain.clear();
    this._terrainWorker.terminate();
  }

  private tick(): void {
    const pos = this.sceneManager.getCameraPosition();
    const cameraCx = Math.floor(pos.x / CHUNK_SIZE);
    const cameraCz = Math.floor(pos.z / CHUNK_SIZE);

    if (cameraCx !== this.lastCameraCx || cameraCz !== this.lastCameraCz) {
      this.lastCameraCx = cameraCx;
      this.lastCameraCz = cameraCz;
      this.updateVisibleColumns(cameraCx, cameraCz);
    }

    this.processQueue();
  }

  private updateVisibleColumns(cameraCx: number, cameraCz: number): void {
    const desired = this.spiralOrder(cameraCx, cameraCz, this.config.renderDistance);
    const desiredSet = new Set(desired);

    // Queue new columns
    for (const key of desired) {
      const state = this.columnStates.get(key);
      if (!state || state === 'failed') {
        this.columnStates.set(key, 'pending');
        this.retryCount.delete(key);
        this.loadQueue.push(key);
      }
    }

    // Unload distant columns
    const toUnload: ColumnKey[] = [];
    for (const [key, state] of this.columnStates) {
      if (desiredSet.has(key)) continue;
      const [cx, cz] = key.split(':').map(Number);
      const dist = Math.max(Math.abs(cx - cameraCx), Math.abs(cz - cameraCz));
      if (dist > this.config.unloadDistance && state !== 'loading') {
        toUnload.push(key);
      }
    }
    for (const key of toUnload) {
      this.unloadColumn(key);
    }
  }

  /** Generate column keys in spiral order outward from center. */
  private spiralOrder(cx: number, cz: number, radius: number): ColumnKey[] {
    const result: ColumnKey[] = [`${cx}:${cz}`];
    for (let r = 1; r <= radius; r++) {
      for (let dx = -r; dx <= r; dx++) result.push(`${cx + dx}:${cz - r}`);
      for (let dz = -r + 1; dz <= r; dz++) result.push(`${cx + r}:${cz + dz}`);
      for (let dx = r - 1; dx >= -r; dx--) result.push(`${cx + dx}:${cz + r}`);
      for (let dz = r - 1; dz >= -r + 1; dz--) result.push(`${cx - r}:${cz + dz}`);
    }
    return result;
  }

  private processQueue(): void {
    while (
      this.loadQueue.length > 0 &&
      this.inFlightCount < this.config.maxConcurrentGens
    ) {
      const key = this.loadQueue.shift()!;
      const state = this.columnStates.get(key);
      if (state !== 'pending') continue;
      this.loadColumn(key);
    }
  }

  private async loadColumn(key: ColumnKey): Promise<void> {
    const epochAtStart = this.epoch;
    const [cx, cz] = key.split(':').map(Number);
    const offsetX = cx * CHUNK_SIZE;
    const offsetZ = cz * CHUNK_SIZE;

    this.inFlightCount++;
    this.columnStates.set(key, 'loading');

    try {
      // Generate terrain in the terrain worker — frees the main thread entirely.
      const blocks = await this._requestTerrain(key, offsetX, offsetZ, CHUNK_SIZE, this.config.seed);

      if (this.epoch !== epochAtStart) return;

      // Feed blocks directly into ChunkManager (bypass WebSocket/BlockObserver)
      for (const block of blocks) {
        this.chunkManager.setBlock(this.namespace, block.x, block.y, block.z, block.type);
      }

      this.columnStates.set(key, 'loaded');
      this.retryCount.delete(key);

      // Request server-side physics collider asynchronously (queued)
      this.enqueueCollider(offsetX, offsetZ, key);
    } catch (err) {
      if (this.epoch === epochAtStart) {
        const retries = (this.retryCount.get(key) ?? 0) + 1;
        this.retryCount.set(key, retries);
        if (retries >= MAX_RETRIES) {
          console.warn('[ChunkLoader] Column failed after retries:', key, err);
          this.columnStates.set(key, 'failed');
        } else {
          console.warn(`[ChunkLoader] Retry ${retries}/${MAX_RETRIES} for`, key);
          this.columnStates.set(key, 'pending');
          this.loadQueue.push(key);
        }
      }
    } finally {
      // Only decrement if epoch matches — otherwise reset() already zeroed it
      if (this.epoch === epochAtStart) {
        this.inFlightCount--;
        this.processQueue();
      }
    }
  }

  /** Post a TerrainRequest to the worker and return a Promise for the result. */
  private _requestTerrain(
    chunkKey: string,
    ox: number,
    oz: number,
    chunkSize: number,
    seed: number,
  ): Promise<TerrainBlock[]> {
    return new Promise<TerrainBlock[]>((resolve, reject) => {
      this._pendingTerrain.set(chunkKey, { resolve, reject });
      this._terrainWorker.postMessage(
        { chunkKey, ox, oz, chunkSize, seed } satisfies TerrainRequest,
      );
    });
  }

  /** Queue a physics collider request and drain the queue. */
  private enqueueCollider(offsetX: number, offsetZ: number, key: ColumnKey): void {
    this.colliderQueue.push({ offsetX, offsetZ, key });
    this.processColliderQueue();
  }

  /** Drain collider queue up to MAX_CONCURRENT_COLLIDER_REQUESTS in-flight. */
  private processColliderQueue(): void {
    while (
      !this._collidersDisabled &&
      this.colliderQueue.length > 0 &&
      this.colliderInFlightCount < MAX_CONCURRENT_COLLIDER_REQUESTS
    ) {
      const req = this.colliderQueue.shift()!;
      // Skip if the column was unloaded while waiting in the queue
      if (!this.columnStates.has(req.key)) continue;
      this.sendColliderRequest(req.offsetX, req.offsetZ);
    }
  }

  /** Send a single collider request to the server. On completion, drains queue. */
  private async sendColliderRequest(
    offsetX: number,
    offsetZ: number,
  ): Promise<void> {
    if (this._collidersDisabled) return;
    const epochAtStart = this.epoch;
    this.colliderInFlightCount++;
    try {
      const goal = `generate_collider(${offsetX}, ${offsetZ}, ${CHUNK_SIZE}, ${this.config.seed}, ${this.config.seaLevel})`;
      await this.proveClient.prove(this.namespace, goal, this._colliderAbort.signal);
      // Success — predicate exists, keep sending for future chunks.
    } catch (err) {
      // Ignore AbortError — these are in-flight requests cancelled by a prior failure.
      if (err instanceof Error && err.name === 'AbortError') return;
      // Any other failure disables colliders immediately — prove_timeout indicates
      // generate_collider/5 is not defined in this namespace (permanent condition).
      // Abort all other in-flight collider requests so they don't produce browser
      // network errors after we've already decided to stop.
      if (!this._collidersDisabled) {
        console.warn('[ChunkLoader] Collider request failed:', offsetX, offsetZ, err);
        this._collidersDisabled = true;
        this.colliderQueue = [];
        this._colliderAbort.abort();
        console.warn(
          '[ChunkLoader] Collider requests disabled — namespace likely lacks bbsvx:voxel subscription',
        );
      }
    } finally {
      if (this.epoch === epochAtStart) {
        this.colliderInFlightCount--;
        this.processColliderQueue();
      }
    }
  }

  private unloadColumn(key: ColumnKey): void {
    const [cx, cz] = key.split(':').map(Number);

    // Remove 3D chunks in this column.
    // Blocks are not in PrologEngine (client-side gen feeds ChunkManager directly),
    // so no Prolog retractall needed.
    // terrain_height range is ~[-15, +20], so with CHUNK_SIZE=32, cy can be -1..0.
    // Use wider range to be safe against future terrain height changes.
    for (let cy = -2; cy <= 2; cy++) {
      const chunkKey3d = `${cx},${cy},${cz}`;
      this.chunkManager.removeChunk(chunkKey3d);
    }
    this.columnStates.delete(key);
    this.retryCount.delete(key);
  }
}
