const DATABASE = 'quod.signed-operations.v2'
const STORE = 'operations'
const DATABASE_VERSION = 1

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
      await request(database, 'readwrite', store => store.put(row))
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

function openDatabase() {
  return new Promise((resolve, reject) => {
    const open = indexedDB.open(DATABASE, DATABASE_VERSION)
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
  return row?.version === 2 && typeof row.id === 'string' && row.id.length === 43 &&
    typeof row.signing_key === 'string' && row.signing_key.length === 43 &&
    typeof row.network === 'string' && row.network.length === 43 &&
    validAgent(row.agent) &&
    typeof row.request === 'string' && row.request.length <= 12_000 &&
    typeof row.signature === 'string' && row.signature.length === 86 &&
    Number.isSafeInteger(row.created_at_ms) && row.created_at_ms > 0
}

function validAgent(agent) {
  return agent && typeof agent.namespace === 'string' && agent.namespace.length > 0 &&
    typeof agent.anchor === 'string' && agent.anchor.length === 43 &&
    typeof agent.instance_text === 'string' && agent.instance_text.length > 0
}
