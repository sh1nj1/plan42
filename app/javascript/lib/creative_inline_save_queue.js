import csrfFetch from "./api/csrf_fetch"

const STORAGE_KEY = "creative-inline-save-queue"
const MAX_RETRIES = 3
const BASE_DELAY_MS = 1000
const MAX_DELAY_MS = 15000

let processing = false
let scheduledTimer = null
const successHandlers = new Set()

function hasStorage() {
  return typeof window !== "undefined" && typeof window.localStorage !== "undefined"
}

function readQueue() {
  if (!hasStorage()) return []
  try {
    const raw = window.localStorage.getItem(STORAGE_KEY)
    if (!raw) return []
    const parsed = JSON.parse(raw)
    return Array.isArray(parsed) ? parsed : []
  } catch (_error) {
    return []
  }
}

function writeQueue(queue) {
  if (!hasStorage()) return
  try {
    window.localStorage.setItem(STORAGE_KEY, JSON.stringify(queue))
  } catch (error) {
    console.error("Failed to persist creative save queue", error)
  }
}

function scheduleProcess(delay = 0) {
  if (scheduledTimer != null) return
  scheduledTimer = setTimeout(() => {
    scheduledTimer = null
    void processQueue()
  }, Math.max(0, delay))
}

function serializeFormData(formData) {
  return Array.from(formData.entries()).map(([key, value]) => [key, typeof value === "string" ? value : String(value)])
}

function deserializeFormData(entries) {
  const fd = new FormData()
  entries.forEach(([key, value]) => fd.append(key, value))
  return fd
}

function notifySuccess(entry) {
  successHandlers.forEach((handler) => {
    try {
      handler(entry)
    } catch (error) {
      console.error("creative inline save success handler failed", error)
    }
  })
}

async function processQueue() {
  if (processing) return
  processing = true
  try {
    while (true) {
      const queue = readQueue()
      if (!queue.length) break
      const entry = queue[0]
      const formData = deserializeFormData(entry.formEntries || [])
      const response = await csrfFetch(entry.url, {
        method: entry.method,
        headers: { Accept: "application/json" },
        body: formData,
      })
      if (!response.ok) throw new Error(`Save request failed with status ${response.status}`)
      queue.shift()
      writeQueue(queue)
      notifySuccess(entry)
    }
  } catch (error) {
    console.error("Failed to process creative inline save queue", error)
    const queue = readQueue()
    if (queue.length > 0) {
      const entry = queue[0]
      const attempts = (entry.attempts || 0) + 1
      entry.attempts = attempts
      if (attempts > MAX_RETRIES) {
        queue.shift()
      }
      writeQueue(queue)
      if (attempts <= MAX_RETRIES) {
        const delay = Math.min(BASE_DELAY_MS * (2 ** (attempts - 1)), MAX_DELAY_MS)
        scheduleProcess(delay)
      }
    }
  } finally {
    processing = false
  }
}

export function enqueueCreativeSave({ url, method = "PATCH", formData, cleanupAttachmentIds = [], meta = {} } = {}) {
  if (!url || !formData) return null
  const hasCrypto = typeof crypto !== "undefined"
  const entry = {
    id: hasCrypto && crypto.randomUUID ? crypto.randomUUID() : `queued-${Date.now()}-${Math.random().toString(16).slice(2)}`,
    url,
    method: method.toUpperCase(),
    formEntries: serializeFormData(formData),
    cleanupAttachmentIds: Array.isArray(cleanupAttachmentIds) ? cleanupAttachmentIds : [],
    meta,
    attempts: 0,
    createdAt: Date.now(),
  }
  const queue = readQueue()
  queue.push(entry)
  writeQueue(queue)
  scheduleProcess()
  return entry.id
}

export function resumeCreativeSaveQueue({ onSuccess } = {}) {
  if (typeof onSuccess === "function") successHandlers.add(onSuccess)
  if (readQueue().length > 0) scheduleProcess()
}

export function clearCreativeSaveQueue() {
  if (!hasStorage()) return
  window.localStorage.removeItem(STORAGE_KEY)
}
