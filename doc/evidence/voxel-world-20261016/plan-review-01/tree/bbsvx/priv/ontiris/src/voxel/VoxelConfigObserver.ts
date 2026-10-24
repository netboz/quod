import type { DiffObserver } from '../prolog/DiffObserver';
import type { ChunkManager } from './ChunkManager';
import type { ChunkLoader } from './ChunkLoader';

/**
 * Watches voxel configuration facts from the ontology:
 * - block_color(Type, R, G, B) -> updates ChunkManager palette color
 * - block_texture(Type, URL)   -> updates ChunkManager palette textureUrl
 * - attribute(Instance, seed, S) -> updates ChunkLoader seed config
 */
export class VoxelConfigObserver implements DiffObserver {
  readonly watchedFunctors = ['block_color', 'block_texture', 'attribute'];

  private chunkManager: ChunkManager;
  private chunkLoader: ChunkLoader | null = null;

  constructor(chunkManager: ChunkManager) {
    this.chunkManager = chunkManager;
  }

  setChunkLoader(loader: ChunkLoader): void {
    this.chunkLoader = loader;
  }

  onAssert(_namespace: string, functor: string, args: unknown[]): void {
    switch (functor) {
      case 'block_color':
        if (args.length >= 4) {
          const [type, r, g, b] = args;
          if (
            typeof r === 'number' &&
            typeof g === 'number' &&
            typeof b === 'number'
          ) {
            this.chunkManager.updatePaletteColor(String(type), r, g, b);
          }
        }
        break;

      case 'block_texture':
        if (args.length >= 2) {
          const [type, url] = args;
          this.chunkManager.updatePaletteTexture(String(type), String(url));
        }
        break;

      case 'attribute':
        if (args.length >= 3 && this.chunkLoader) {
          const [_instance, attrName, value] = args;
          const name = String(attrName);
          if (name === 'seed' && typeof value === 'number') {
            console.log('[VoxelConfigObserver] Seed from ontology:', value);
            this.chunkLoader.updateConfig({ seed: value });
          }
        }
        break;
    }
  }

  onRetract(_namespace: string, _functor: string, _args: unknown[]): void {}

  onAbolish(_namespace: string, _functor: string, _arity: number): void {}

  onClear(_namespace: string): void {
    this.chunkLoader?.reset();
  }
}
