const MAX_DRAFTS = 50
const DRAFT_TTL_MS = 7 * 24 * 60 * 60 * 1000
const CLEAR_EVENT_KEY = 'collavre_chat_drafts_clear'
const KEY_SEPARATOR = ':'

const createMemoryStorage = () => {
  const values = new Map()
  return {
    get length() { return values.size },
    key: (index) => [...values.keys()][index] ?? null,
    getItem: (key) => values.get(String(key)) ?? null,
    setItem: (key, value) => values.set(String(key), String(value)),
    removeItem: (key) => values.delete(String(key)),
  }
}

/**
 * Per-user persistent store for unsent chat input drafts.
 *
 * Draft changes use immutable per-chat operation keys. Concurrent tabs can
 * therefore append without replacing another chat's state or racing a
 * read-modify-write snapshot. The greatest timestamp/version wins. Deletions
 * remain as bounded tombstones until the seven-day TTL prevents stale tabs
 * from restoring cleared text.
 */
class ChatDrafts {
  constructor(storage = null, backupStorage = null) {
    this._storage = storage
    this._backupStorage = backupStorage
    this._fallbackStorage = createMemoryStorage()
    this._fallbackBackupStorage = createMemoryStorage()
    this._writerId = `${Date.now()}-${Math.random()}`
    this._sequence = 0
    this._pendingClearNonces = new Map()
  }

  get(chatId) {
    if (!chatId) return null
    const entry = this._entry(String(chatId))
    return entry && !entry.deleted ? entry.text : null
  }

  updatedAt(chatId) {
    if (!chatId) return null
    const entry = this._entry(String(chatId))
    if (!entry || entry.movedTo || (entry.deleted && !entry.migration)) return null
    return entry.updatedAt
  }

  revision(chatId) {
    if (!chatId) return null
    const entry = this._entry(String(chatId))
    if (!entry || entry.movedTo || (entry.deleted && !entry.migration)) return null
    return entry.version
  }

  snapshot(chatId) {
    if (!chatId) return { text: null, revision: null, updatedAt: null }

    const entry = this._entry(String(chatId))
    const hasRevision =
      entry && !entry.movedTo && (!entry.deleted || entry.migration)
    return {
      text: entry && !entry.deleted ? entry.text : null,
      revision: hasRevision ? entry.version : null,
      updatedAt: entry && !entry.movedTo ? entry.updatedAt : null,
    }
  }

  isNewer(sourceChatId, targetChatId) {
    if (!sourceChatId) return false

    const source = this._entry(String(sourceChatId))
    if (!source) return false
    const target = targetChatId ? this._entry(String(targetChatId)) : null
    return this._compare(source, target) > 0
  }

  saveSubmissionBackup(chatId, text, { updatedAt = null } = {}) {
    if (!chatId || !text || !text.trim()) return null

    const id = String(chatId)
    const current = updatedAt === null ? this._entry(id) : null
    const backupUpdatedAt = updatedAt ??
      Math.max(Date.now(), (current?.updatedAt || 0) + 1)
    this._sequence += 1
    const version = `${backupUpdatedAt}-${this._writerId}-${this._sequence}`
    const key = `${this._backupPrefix(id)}${encodeURIComponent(version)}`
    const candidate = { key, text, updatedAt: backupUpdatedAt }
    const existing = this.latestSubmissionBackup(id)
    if (existing && this._compareSubmissionBackups(existing, candidate) >= 0) return null

    try {
      this._backupBackend().setItem(key, JSON.stringify({ text, updatedAt: backupUpdatedAt }))
      const backups = this._submissionBackups(id)
      const latest = [...backups].sort((left, right) => (
	this._compareSubmissionBackups(right, left)
      ))[0]
      if (!latest || latest.key !== key) {
	this.removeSubmissionBackup(key)
	return null
      }
      const superseded = backups.filter((backup) => (
	backup.key !== key && this._compareSubmissionBackups(backup, candidate) < 0
      ))
      if (!superseded.every((backup) => this.removeSubmissionBackup(backup.key))) {
	return this.removeSubmissionBackup(key) ? null : key
      }
      this._evictSubmissionBackups()
      return key
    } catch {
      return null
    }
  }

  latestSubmissionBackup(chatId) {
    if (!chatId) return null

    return this._submissionBackups(String(chatId)).sort((left, right) => (
      this._compareSubmissionBackups(right, left)
    ))[0] || null
  }

  removeSubmissionBackup(key, namespace = this._key()) {
    if (!key || !key.startsWith(this._backupPrefix(null, namespace))) return false

    try {
      this._backupBackend().removeItem(key)
      return this._backupBackend().getItem(key) === null
    } catch {
      return false
    }
  }

  clearSubmissionBackups(chatId) {
    if (!chatId) return false
    return this._keys(
      this._backupPrefix(String(chatId)),
      this._backupBackend(),
    ).every((key) => this.removeSubmissionBackup(key))
  }

  clearSubmissionBackupsThrough(key, namespace = this._key()) {
    if (!key || !key.startsWith(this._backupPrefix(null, namespace))) return false

    const backups = this._submissionBackups(null, namespace)
    const candidate = backups.find((backup) => backup.key === key)
    if (!candidate) return false

    const chatPrefix = key.slice(0, key.lastIndexOf(KEY_SEPARATOR) + 1)
    const superseded = backups.filter((backup) => (
      backup.key.startsWith(chatPrefix) &&
      this._compareSubmissionBackups(backup, candidate) <= 0
    )).sort((left, right) => this._compareSubmissionBackups(left, right))
    return superseded.every((backup) => (
      this.removeSubmissionBackup(backup.key, namespace)
    ))
  }

  clearSubmissionBackupsForClear(namespace, nonce) {
    if (!namespace || !nonce) return false

    const backend = this._backupBackend()
    if (
      !this._backupStorage &&
      !this._storage &&
      backend === this._fallbackBackupStorage
    ) return false
    const acknowledgementKey = `${CLEAR_EVENT_KEY}${KEY_SEPARATOR}${encodeURIComponent(namespace)}`
    try {
      if (backend.getItem(acknowledgementKey) === nonce) return true

      const backupsCleared = this._keys(
	this._backupPrefix(null, namespace),
	backend,
      ).every((key) => this.removeSubmissionBackup(key, namespace))
      if (!backupsCleared) return false

      backend.setItem(acknowledgementKey, nonce)
      return backend.getItem(acknowledgementKey) === nonce
    } catch {
      return false
    }
  }

  moveSubmissionBackups(sourceChatId, targetChatId) {
    const moved = new Map()
    if (!sourceChatId || !targetChatId) return moved

    const sourceId = String(sourceChatId)
    const targetId = String(targetChatId)
    if (sourceId === targetId) return moved

    const sourcePrefix = this._backupPrefix(sourceId)
    const targetPrefix = this._backupPrefix(targetId)
    this._submissionBackups(sourceId).forEach(({ key, text, updatedAt }) => {
      const target = this.latestSubmissionBackup(targetId)
      if (target && (
        target.updatedAt > updatedAt ||
        (
          target.updatedAt === updatedAt &&
          target.key.slice(targetPrefix.length).localeCompare(
            key.slice(sourcePrefix.length),
          ) >= 0
        )
      )) {
        this.removeSubmissionBackup(key)
        return
      }

      const targetBackups = this._submissionBackups(targetId)
      const restoreTargetBackups = () => {
	const backend = this._backupBackend()
	targetBackups.forEach((backup) => {
	  try {
	    backend.setItem(backup.key, JSON.stringify({
	      text: backup.text,
	      updatedAt: backup.updatedAt,
	    }))
	  } catch {
	    // Keep any target backup that storage still allows.
	  }
	})
      }
      if (!this.clearSubmissionBackups(targetId)) {
	restoreTargetBackups()
	return
      }

      const targetKey = `${targetPrefix}${key.slice(sourcePrefix.length)}`
      const value = JSON.stringify({ text, updatedAt })
      try {
        this._backupBackend().setItem(targetKey, value)
	if (this._backupBackend().getItem(targetKey) !== value) {
	  restoreTargetBackups()
	  return
	}
        if (!this.removeSubmissionBackup(key)) {
          this.removeSubmissionBackup(targetKey)
	  restoreTargetBackups()
          return
        }
        moved.set(key, targetKey)
      } catch {
	restoreTargetBackups()
      }
    })
    this._evictSubmissionBackups()
    return moved
  }

  set(chatId, text, { preserveBlank = false } = {}) {
    if (!chatId) return

    const id = String(chatId)
    const current = this._entry(id)
    if (!text || !text.trim()) {
      if (preserveBlank) {
        this._append(id, this._newEntry('', current, { deleted: true, migration: true }))
      } else if (current && !current.deleted) {
        this._append(id, this._newEntry('', current, {
          deleted: true,
          deletesThrough: this._versionOf(current),
        }))
      } else {
        return
      }
    } else {
      this._append(id, this._newEntry(text, current))
    }
    this._compact(id)
    this._evict()
  }

  clear(chatId) {
    this.set(chatId, '')
  }

  move(sourceChatId, targetChatId) {
    if (!sourceChatId || !targetChatId) return false

    const sourceId = String(sourceChatId)
    const targetId = String(targetChatId)
    if (sourceId === targetId) return true

    for (let attempt = 0; attempt < 3; attempt += 1) {
      const source = this._entry(sourceId)
      if (!source || source.movedTo === targetId) return true

      const target = this._entry(targetId)
      const shouldCopyToTarget = target
        ? this._compare(source, target) > 0
        : !source.deleted
      if (shouldCopyToTarget) {
        if (!this._append(targetId, {
          ...source,
          migration: false,
          movedTo: undefined,
          deletesThrough: source.deleted
            ? this._versionOf(target)
            : undefined,
	})) return false
        this._compact(targetId)
      }

      if (!this._sameEntry(source, this._entry(sourceId))) continue

      const marker = this._newEntry('', source, {
        deleted: true,
        migration: false,
        movedTo: targetId,
        deletesThrough: this._versionOf(source),
      })
      if (!this._append(sourceId, marker)) return false
      this._compact(sourceId)
      if (this._sameEntry(marker, this._entry(sourceId))) return true
    }
    return false
  }

  clearAll({ broadcast = true } = {}) {
    const backend = this._backend()
    const namespace = this._key()
    this._keys().forEach((key) => {
      try {
        backend.removeItem(key)
      } catch {
        // Storage unavailable.
      }
    })
    this._keys(this._backupPrefix(), this._backupBackend()).forEach((key) => {
      this.removeSubmissionBackup(key)
    })
    try {
      backend.removeItem(namespace)
    } catch {
      // Storage unavailable.
    }
    if (!broadcast) return

    const updatedAt = Date.now()
    const nonce = `${updatedAt}-${Math.random()}`
    const signal = {
      namespace,
      nonce,
      updatedAt,
    }
    const serializedSignal = JSON.stringify(signal)
    try {
      backend.setItem(CLEAR_EVENT_KEY, serializedSignal)
    } catch {
      // Storage unavailable.
    }
    const legacyResult = this._readClearSignal(backend, CLEAR_EVENT_KEY)
    try {
      backend.setItem(this._clearEventKey(namespace), JSON.stringify({
	...signal,
	legacyNamespace: legacyResult.signal?.namespace || null,
	legacyNonce: legacyResult.signal?.nonce || null,
      }))
    } catch {
      // Storage unavailable.
    }
  }

  wasCleared(event) {
    if (
      !event?.newValue ||
      ![CLEAR_EVENT_KEY, this._clearEventKey()].includes(event.key)
    ) return false

    try {
      return JSON.parse(event.newValue)?.namespace === this._key()
    } catch {
      return false
    }
  }

  clearNonce(namespace = this._key()) {
    const backend = this._backend()
    if (!this._storage && backend === this._fallbackStorage) return undefined

    const namespacedKey = this._clearEventKey(namespace)
    const namespacedResult = this._readClearSignal(backend, namespacedKey)
    const legacyResult = this._readClearSignal(backend, CLEAR_EVENT_KEY)
    const namespacedSignal = namespacedResult.signal?.namespace === namespace
      ? namespacedResult.signal
      : null
    const legacySignal = legacyResult.signal?.namespace === namespace
      ? legacyResult.signal
      : null
    const pendingNonce = this._pendingClearNonces.get(namespace)
    if (
      pendingNonce &&
      namespacedSignal?.nonce === pendingNonce &&
      namespacedSignal.legacyNamespace === namespace &&
      namespacedSignal.legacyNonce === pendingNonce
    ) {
      this._pendingClearNonces.delete(namespace)
    }
    let signal = namespacedSignal || legacySignal
    let promoteLegacy = false
    if (
      legacySignal &&
      legacySignal.nonce !== namespacedSignal?.nonce
    ) {
      const hasLegacyBaseline = namespacedSignal &&
	Object.hasOwn(namespacedSignal, 'legacyNamespace') &&
	Object.hasOwn(namespacedSignal, 'legacyNonce')
      const matchesLegacyBaseline = hasLegacyBaseline &&
	namespacedSignal.legacyNamespace === legacySignal.namespace &&
	namespacedSignal.legacyNonce === legacySignal.nonce
      promoteLegacy = !matchesLegacyBaseline && (
	hasLegacyBaseline ||
	this._compareClearSignals(legacySignal, namespacedSignal) >= 0
      )
    }
    if (!signal) {
      return namespacedResult.available && legacyResult.available ? null : undefined
    }
    if (!signal.nonce) return null
    if (promoteLegacy || !namespacedSignal) {
      const promotedSignal = {
	...legacySignal,
	legacyNamespace: legacySignal.namespace,
	legacyNonce: legacySignal.nonce,
      }
      try {
	backend.setItem(namespacedKey, JSON.stringify(promotedSignal))
      } catch {
	this._pendingClearNonces.set(namespace, promotedSignal.nonce)
	return promotedSignal.nonce
      }
      const promotedResult = this._readClearSignal(backend, namespacedKey)
      if (
	!promotedResult.available ||
	promotedResult.signal?.nonce !== promotedSignal.nonce ||
	promotedResult.signal?.legacyNonce !== promotedSignal.legacyNonce
      ) {
	this._pendingClearNonces.set(namespace, promotedSignal.nonce)
	return promotedSignal.nonce
      }
      this._pendingClearNonces.delete(namespace)
      signal = promotedSignal
    }
    return signal.nonce
  }

  clearNoncePending(namespace = this._key()) {
    return this._pendingClearNonces.has(namespace)
  }

  namespace() {
    return this._key()
  }

  _backend() {
    if (this._storage) return this._storage

    try {
      return window.localStorage
    } catch {
      return this._fallbackStorage
    }
  }

  _backupBackend() {
    if (this._backupStorage) return this._backupStorage
    if (this._storage) return this._storage

    try {
      return window.sessionStorage
    } catch {
      return this._fallbackBackupStorage
    }
  }

  _key() {
    const userId = document.body?.dataset?.currentUserId || 'guest'
    return `collavre_chat_drafts_${userId}`
  }

  _clearEventKey(namespace = this._key()) {
    return `${CLEAR_EVENT_KEY}${KEY_SEPARATOR}${encodeURIComponent(namespace)}`
  }

  _compareClearSignals(left, right) {
    const updatedAt = (signal) => {
      const value = Number(signal?.updatedAt ?? String(signal?.nonce).split('-')[0])
      return Number.isFinite(value) ? value : 0
    }
    return updatedAt(left) - updatedAt(right)
  }

  _readClearSignal(backend, key) {
    let value
    try {
      value = backend.getItem(key)
    } catch {
      return { available: false, signal: null }
    }
    if (!value) return { available: true, signal: null }

    try {
      return { available: true, signal: JSON.parse(value) }
    } catch {
      return { available: true, signal: null }
    }
  }

  _prefix() {
    return `${this._key()}${KEY_SEPARATOR}`
  }

  _chatPrefix(chatId) {
    return `${this._prefix()}${encodeURIComponent(chatId)}${KEY_SEPARATOR}`
  }

  _backupPrefix(chatId = null, namespace = this._key()) {
    const prefix = `${namespace}_pending${KEY_SEPARATOR}`
    return chatId === null
      ? prefix
      : `${prefix}${encodeURIComponent(chatId)}${KEY_SEPARATOR}`
  }

  _operationKey(chatId, version) {
    return `${this._chatPrefix(chatId)}${encodeURIComponent(version)}`
  }

  _keys(prefix = this._prefix(), backend = this._backend()) {
    if (typeof backend.key !== 'function' || typeof backend.length !== 'number') return []

    const keys = []
    for (let index = 0; index < backend.length; index += 1) {
      try {
        const key = backend.key(index)
        if (key?.startsWith(prefix)) keys.push(key)
      } catch {
        return keys
      }
    }
    return keys
  }

  _entry(chatId) {
    this._pruneOperations()
    const operations = this._keys(this._chatPrefix(chatId)).flatMap((key) => {
      const entry = this._readOperation(key)
      return entry ? [entry] : []
    })
    return this._resolve(operations)
  }

  _readOperation(key) {
    const backend = this._backend()
    let entry
    try {
      const raw = backend.getItem(key)
      if (!raw) return null
      entry = JSON.parse(raw)
    } catch {
      try {
        backend.removeItem(key)
      } catch {
        // Storage unavailable.
      }
      return null
    }

    if (!this._valid(entry)) {
      try {
        backend.removeItem(key)
      } catch {
        // Storage unavailable.
      }
      return null
    }
    return entry
  }

  _pruneOperations() {
    try {
      // Discard the obsolete aggregate format; current drafts use operation keys.
      this._backend().removeItem(this._key())
    } catch {
      // Storage unavailable.
    }
    this._keys().forEach((key) => this._readOperation(key))
    this._evictSubmissionBackups()
  }

  _submissionBackups(chatId = null, namespace = this._key()) {
    const prefix = this._backupPrefix(chatId, namespace)
    const cutoff = Date.now() - DRAFT_TTL_MS

    const backend = this._backupBackend()
    return this._keys(prefix, backend).flatMap((key) => {
      try {
        const entry = JSON.parse(backend.getItem(key))
        if (
          !entry ||
          typeof entry.text !== 'string' ||
          !entry.text.trim() ||
          !Number.isFinite(entry.updatedAt) ||
          entry.updatedAt < cutoff
        ) throw new Error('Invalid submission backup')

        return [{ key, text: entry.text, updatedAt: entry.updatedAt }]
      } catch {
        this.removeSubmissionBackup(key)
        return []
      }
    })
  }

  _evictSubmissionBackups() {
    const backups = this._submissionBackups().sort((left, right) => (
      this._compareSubmissionBackups(right, left)
    ))
    backups.slice(MAX_DRAFTS).forEach(({ key }) => this.removeSubmissionBackup(key))
  }

  _compareSubmissionBackups(left, right) {
    return left.updatedAt - right.updatedAt || left.key.localeCompare(right.key)
  }

  _valid(entry) {
    return Boolean(
      entry &&
      typeof entry.text === 'string' &&
      Number.isFinite(entry.updatedAt) &&
      typeof entry.version === 'string' &&
      (entry.deleted === undefined || typeof entry.deleted === 'boolean') &&
      (entry.migration === undefined || typeof entry.migration === 'boolean') &&
      (entry.movedTo === undefined || typeof entry.movedTo === 'string') &&
      (
        entry.deletesThrough === undefined ||
        (
          entry.deletesThrough &&
          Number.isFinite(entry.deletesThrough.updatedAt) &&
          typeof entry.deletesThrough.version === 'string'
        )
      ) &&
      entry.updatedAt >= Date.now() - DRAFT_TTL_MS,
    )
  }

  _newEntry(text, previous, options = {}) {
    const updatedAt = Math.max(Date.now(), (previous?.updatedAt || 0) + 1)
    this._sequence += 1
    return {
      text,
      updatedAt,
      version: `${updatedAt}-${this._writerId}-${this._sequence}`,
      ...options,
    }
  }

  _compare(left, right) {
    if (!right) return 1
    if (left.updatedAt !== right.updatedAt) return left.updatedAt - right.updatedAt
    return left.version.localeCompare(right.version)
  }

  _sameEntry(left, right) {
    return Boolean(
      right &&
      left.text === right.text &&
      left.updatedAt === right.updatedAt &&
      left.version === right.version &&
      Boolean(left.deleted) === Boolean(right.deleted) &&
      Boolean(left.migration) === Boolean(right.migration) &&
      left.movedTo === right.movedTo &&
      left.deletesThrough?.updatedAt === right.deletesThrough?.updatedAt &&
      left.deletesThrough?.version === right.deletesThrough?.version,
    )
  }

  _versionOf(entry) {
    return { updatedAt: entry.updatedAt, version: entry.version }
  }

  _resolve(operations) {
    const sorted = [...operations].sort((left, right) => this._compare(right, left))
    return sorted.find((entry) => (
      !entry.deletesThrough ||
      !operations.some((candidate) => (
	!this._sameEntry(candidate, entry) &&
	(entry.movedTo || !candidate.deletesThrough) &&
        this._compare(candidate, entry.deletesThrough) > 0
      ))
    )) || null
  }

  _append(chatId, entry) {
    const key = this._operationKey(chatId, entry.version)
    for (let attempt = 0; attempt < 3; attempt += 1) {
      try {
        this._backend().setItem(key, JSON.stringify(entry))
      } catch {
        return false
      }
      if (this._sameEntry(entry, this._readOperation(key))) return true
    }
    return false
  }

  _compact(chatId) {
    const keys = this._keys(this._chatPrefix(chatId))
    const operations = keys.flatMap((key) => {
      const entry = this._readOperation(key)
      return entry ? [{ key, entry }] : []
    })
    if (operations.length <= 1) return

    const resolved = this._resolve(operations.map(({ entry }) => entry))
    const guard = operations.reduce((latest, operation) => {
      if (!operation.entry.deleted) return latest
      if (!latest) return operation

      const ceilingComparison = this._compare(
        this._deletionCeiling(operation.entry),
        this._deletionCeiling(latest.entry),
      )
      if (ceilingComparison !== 0) return ceilingComparison > 0 ? operation : latest
      return this._compare(operation.entry, latest.entry) > 0 ? operation : latest
    }, null)
    operations.filter(({ entry }) => (
      !this._sameEntry(entry, resolved) &&
      (!guard || !this._sameEntry(entry, guard.entry))
    )).forEach(({ key }) => {
      try {
        this._backend().removeItem(key)
      } catch {
        // Storage unavailable.
      }
    })
  }

  _entries() {
    this._pruneOperations()
    const operations = new Map()
    this._keys().forEach((key) => {
      const entry = this._readOperation(key)
      if (!entry) return
      const suffix = key.slice(this._prefix().length)
      let id
      try {
        id = decodeURIComponent(suffix.slice(0, suffix.indexOf(KEY_SEPARATOR)))
      } catch {
        try {
          this._backend().removeItem(key)
        } catch {
          // Storage unavailable.
        }
        return
      }
      if (!operations.has(id)) operations.set(id, [])
      operations.get(id).push(entry)
    })
    return [...operations].map(([id, entries]) => ({ id, entry: this._resolve(entries) }))
  }

  _evict() {
    const entries = this._entries().filter(({ entry }) => !entry.deleted)
    if (entries.length > MAX_DRAFTS) {
      entries.sort((left, right) => this._compare(left.entry, right.entry))
      entries.slice(0, entries.length - MAX_DRAFTS).forEach(({ id, entry }) => {
        this._append(id, this._newEntry('', entry, {
          deleted: true,
          deletesThrough: this._versionOf(entry),
        }))
        this._compact(id)
      })
    }
  }

  _deletionCeiling(entry) {
    return entry.deletesThrough || this._versionOf(entry)
  }
}

const chatDrafts = new ChatDrafts()

export default chatDrafts
export { ChatDrafts }
