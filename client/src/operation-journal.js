const DATABASE = 'quod.signed-operations.v1'
const STORE = 'operations'
const VERSION = 1
const MAX_OPERATIONS = 64

let browserJournal

// The browser owns only unresolved exact request bytes. The ledger remains the
// authority for their outcome; IndexedDB merely prevents a reload from turning
// uncertainty into a newly signed operation.
export function signedOperationJournal() {
  if (browserJournal) return browserJournal
  if (!globalThis.indexedDB) {
    throw new Error('durable browser storage is unavailable; signed writes are disabled')
  }
  browserJournal = indexedDbJournal()
  return browserJournal
}

export function memoryOperationJournal() {
  const rows = new Map()
  return {
    async put(row) {
      validateRow(row)
      if (!rows.has(row.id) && rows.size >= MAX_OPERATIONS) {
        throw new Error('too many unresolved signed operations')
      }
      rows.set(row.id, structuredClone(row))
    },
    async delete(id) { rows.delete(id) },
    async list() { return [...rows.values()].map(row => structuredClone(row)) },
  }
}

function indexedDbJournal() {
  const database = openDatabase()
  return {
    async put(row) {
      validateRow(row)
      await boundedPut(database, row)
    },
    async delete(id) {
      await request(database, 'readwrite', store => store.delete(id))
    },
    async list() {
      const rows = await request(database, 'readonly', store => store.getAll())
      return rows.filter(validRow)
    },
  }
}

async function boundedPut(databasePromise, row) {
  const database = await databasePromise
  return new Promise((resolve, reject) => {
    const transaction = database.transaction(STORE, 'readwrite')
    const store = transaction.objectStore(STORE)
    let admissionError
    const keys = store.getAllKeys()
    keys.onsuccess = () => {
      const existing = keys.result.includes(row.id)
      if (!existing && keys.result.length >= MAX_OPERATIONS) {
        admissionError = new Error('too many unresolved signed operations')
        transaction.abort()
        return
      }
      store.put(row)
    }
    keys.onerror = () => {
      admissionError = keys.error || new Error('could not inspect operation journal')
      transaction.abort()
    }
    transaction.oncomplete = () => resolve()
    transaction.onerror = () => reject(
      admissionError || transaction.error ||
        new Error('operation journal transaction failed'),
    )
    transaction.onabort = transaction.onerror
  })
}

function openDatabase() {
  return new Promise((resolve, reject) => {
    const open = indexedDB.open(DATABASE, VERSION)
    open.onupgradeneeded = () => {
      if (!open.result.objectStoreNames.contains(STORE)) {
        open.result.createObjectStore(STORE, { keyPath: 'id' })
      }
    }
    open.onsuccess = () => resolve(open.result)
    open.onerror = () => reject(open.error || new Error('could not open operation journal'))
    open.onblocked = () => reject(new Error('operation journal upgrade is blocked'))
  })
}

async function request(databasePromise, mode, operation) {
  const database = await databasePromise
  return new Promise((resolve, reject) => {
    const transaction = database.transaction(STORE, mode)
    const result = operation(transaction.objectStore(STORE))
    transaction.oncomplete = () => resolve(result.result)
    transaction.onerror = () => reject(
      transaction.error || new Error('operation journal transaction failed'),
    )
    transaction.onabort = transaction.onerror
  })
}

function validateRow(row) {
  if (!validRow(row)) throw new Error('invalid operation journal row')
}

function validRow(row) {
  return row?.version === VERSION && typeof row.id === 'string' && row.id.length === 43 &&
    typeof row.user === 'string' && row.user.length === 43 &&
    typeof row.network === 'string' && row.network.length === 43 &&
    typeof row.request === 'string' && row.request.length <= 12_000 &&
    typeof row.signature === 'string' && row.signature.length === 86 &&
    Number.isSafeInteger(row.created_at_ms) && row.created_at_ms > 0
}
