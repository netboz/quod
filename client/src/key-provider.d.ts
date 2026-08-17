import type { KeyProvider } from './signed-client.js'

export function createKeyProvider(): Promise<KeyProvider>
export function loadLocalKeyProvider(passphrase: string): Promise<KeyProvider>
export function importEncryptedKeyProvider(encoded: string, passphrase: string): Promise<KeyProvider>
export function saveLocalKeyProvider(provider: KeyProvider, passphrase: string): Promise<void>
export function exportEncryptedKeyProvider(provider: KeyProvider, passphrase: string): Promise<string>
export function storeActiveKeyProvider(provider: KeyProvider): Promise<void>
export function loadActiveKeyProvider(): Promise<KeyProvider | null>
export function clearActiveKeyProvider(): Promise<void>
export function hasLocalKeyProvider(): boolean
export function localKeyMatches(provider: KeyProvider): boolean
export function b64url(bytes: Uint8Array): string
export function fromB64url(value: string): Uint8Array
