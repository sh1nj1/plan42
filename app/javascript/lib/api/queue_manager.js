import csrfFetch from './csrf_fetch'

const STORAGE_KEY = 'api_queue'
const MAX_RETRIES = 3

/**
 * API Queue Manager
 * Manages asynchronous API requests with localStorage persistence,
 * sequential processing, retry logic, and deduplication.
 */
class ApiQueueManager {
    constructor() {
        this.queue = []
        this.processing = false
        this.loadFromLocalStorage()
        this.setupNetworkListeners()
    }

    /**
     * Load pending requests from localStorage
     */
    loadFromLocalStorage() {
        try {
            const stored = localStorage.getItem(STORAGE_KEY)
            if (stored) {
                this.queue = JSON.parse(stored)
                // Process queue on page load if there are pending items
                if (this.queue.length > 0) {
                    this.processQueue()
                }
            }
        } catch (error) {
            console.error('Failed to load API queue from localStorage:', error)
            this.queue = []
        }
    }

    /**
     * Save queue to localStorage
     * Items with onSuccess callbacks are excluded because functions cannot be serialized
     * Items with deletedAttachmentIds are included because they're serializable data
     */
    saveToLocalStorage() {
        try {
            // Filter out items with onSuccess callbacks (non-serializable)
            // but keep items with deletedAttachmentIds (serializable data)
            const serializableQueue = this.queue.filter(item => !item.onSuccess)
            localStorage.setItem(STORAGE_KEY, JSON.stringify(serializableQueue))
        } catch (error) {
            console.error('Failed to save API queue to localStorage:', error)
        }
    }

    /**
     * Setup network status listeners
     */
    setupNetworkListeners() {
        window.addEventListener('online', () => {
            console.log('Network online - processing queue')
            this.processQueue()
        })

        window.addEventListener('offline', () => {
            console.log('Network offline - queue will resume when online')
        })
    }

    /**
     * Add a request to the queue
     * @param {Object} request - Request configuration
     * @param {string} request.path - API path
     * @param {string} request.method - HTTP method (GET, POST, PATCH, DELETE)
     * @param {Object} request.params - URL parameters
     * @param {Object} request.body - Request body
     * @param {string} request.dedupeKey - Optional key for deduplication
     * @param {Function} request.onSuccess - Optional callback to run after successful request
     * @returns {string} Request ID
     */
    enqueue(request) {
        // Find and merge callbacks and attachment IDs from existing requests with the same dedupeKey
        let existingCallbacks = []
        let existingAttachmentIds = []
        if (request.dedupeKey) {
            // CRITICAL: Skip the first item if processing is active
            // The first item might be currently executing in processQueue
            // Removing it would cause shift() to remove the wrong item
            const startIndex = this.processing ? 1 : 0
            const existingItems = this.queue.slice(startIndex).filter(item => item.dedupeKey === request.dedupeKey)

            existingItems.forEach(item => {
                if (typeof item.onSuccess === 'function') {
                    existingCallbacks.push(item.onSuccess)
                }
                if (item.deletedAttachmentIds && item.deletedAttachmentIds.length > 0) {
                    existingAttachmentIds.push(...item.deletedAttachmentIds)
                }
            })

            // Remove existing requests with the same dedupeKey
            // CRITICAL: Keep the first item if processing is active
            if (this.processing) {
                const firstItem = this.queue[0]
                this.queue = [firstItem, ...this.queue.slice(1).filter(item => item.dedupeKey !== request.dedupeKey)]
            } else {
                this.queue = this.queue.filter(item => item.dedupeKey !== request.dedupeKey)
            }
        }

        // Merge attachment IDs
        let mergedAttachmentIds = null
        if (request.deletedAttachmentIds && request.deletedAttachmentIds.length > 0) {
            existingAttachmentIds.push(...request.deletedAttachmentIds)
        }
        if (existingAttachmentIds.length > 0) {
            // Remove duplicates
            mergedAttachmentIds = [...new Set(existingAttachmentIds)]
        }

        // Merge new callback with existing callbacks
        let mergedCallback = null
        if (existingCallbacks.length > 0 || request.onSuccess) {
            mergedCallback = () => {
                // Run all existing callbacks first
                existingCallbacks.forEach(cb => {
                    try {
                        cb()
                    } catch (error) {
                        console.error('Merged callback failed:', error)
                    }
                })
                // Then run the new callback
                if (typeof request.onSuccess === 'function') {
                    try {
                        request.onSuccess()
                    } catch (error) {
                        console.error('New callback failed:', error)
                    }
                }
            }
        }

        const queueItem = {
            id: `${Date.now()}_${Math.random().toString(36).substr(2, 9)}`,
            path: request.path,
            method: request.method || 'GET',
            params: request.params || null,
            body: request.body || null,
            dedupeKey: request.dedupeKey || null,
            deletedAttachmentIds: mergedAttachmentIds,
            onSuccess: mergedCallback,
            timestamp: Date.now(),
            retries: 0
        }

        this.queue.push(queueItem)
        this.saveToLocalStorage()

        // Start processing if not already processing
        this.processQueue()

        return queueItem.id
    }

    /**
     * Process all queued requests sequentially
     */
    async processQueue() {
        if (this.processing || this.queue.length === 0) {
            return
        }

        this.processing = true

        while (this.queue.length > 0) {
            const item = this.queue[0]

            try {
                await this.executeRequest(item)
                // Success - handle cleanup actions

                // Dispatch event for attachment cleanup if needed
                if (item.deletedAttachmentIds && item.deletedAttachmentIds.length > 0) {
                    window.dispatchEvent(new CustomEvent('api-queue-attachments-deleted', {
                        detail: { attachmentIds: item.deletedAttachmentIds }
                    }))
                }

                // Call onSuccess callback if provided (for non-serializable actions)
                if (typeof item.onSuccess === 'function') {
                    try {
                        item.onSuccess()
                    } catch (callbackError) {
                        console.error('onSuccess callback failed:', callbackError)
                    }
                }

                // Remove from queue
                this.queue.shift()
                this.saveToLocalStorage()
            } catch (error) {
                console.error('API request failed:', error, item)

                // Retry logic
                if (item.retries < MAX_RETRIES) {
                    item.retries++
                    // Move to end of queue for retry
                    this.queue.shift()
                    this.queue.push(item)
                    this.saveToLocalStorage()
                } else {
                    // Max retries exceeded - remove from queue
                    console.error('Max retries exceeded, discarding request:', item)
                    this.queue.shift()
                    this.saveToLocalStorage()
                    this.handleFailedRequest(item, error)
                }

                // If network error, stop processing and wait for online event
                if (!navigator.onLine) {
                    console.log('Network offline - pausing queue processing')
                    break
                }
            }
        }

        this.processing = false
    }

    /**
     * Execute a single API request
     * @param {Object} item - Queue item
     * @returns {Promise<Response>}
     */
    async executeRequest(item) {
        let url = item.path

        // Add query parameters if present
        if (item.params) {
            const params = new URLSearchParams()
            Object.keys(item.params).forEach(key => {
                params.append(key, item.params[key])
            })
            const queryString = params.toString()
            if (queryString) {
                url = `${url}?${queryString}`
            }
        }

        const options = {
            method: item.method,
            headers: {
                'Accept': 'application/json'
            }
        }

        // Add body for POST/PATCH/PUT requests
        if (item.body && ['POST', 'PATCH', 'PUT'].includes(item.method)) {
            // If body is FormData-like object, convert to FormData
            if (item.body && typeof item.body === 'object') {
                const formData = new FormData()
                Object.keys(item.body).forEach(key => {
                    const value = item.body[key]
                    if (value !== null && value !== undefined) {
                        formData.append(key, value)
                    }
                })
                options.body = formData
            } else {
                options.body = item.body
            }
        }

        const response = await csrfFetch(url, options)

        if (!response.ok) {
            throw new Error(`HTTP ${response.status}: ${response.statusText}`)
        }

        return response
    }

    /**
     * Handle permanently failed requests
     * @param {Object} item - Failed queue item
     * @param {Error} error - Error object
     */
    handleFailedRequest(item, error) {
        // Log to console or send to error tracking service
        console.error('Request permanently failed:', {
            item,
            error: error.message,
            timestamp: new Date().toISOString()
        })

        // Could dispatch a custom event for UI notification
        window.dispatchEvent(new CustomEvent('api-queue-request-failed', {
            detail: { item, error }
        }))
    }

    /**
     * Clear all queued requests
     */
    clear() {
        this.queue = []
        this.saveToLocalStorage()
    }

    /**
     * Get current queue status
     * @returns {Object} Queue status
     */
    getStatus() {
        return {
            queueLength: this.queue.length,
            processing: this.processing,
            items: this.queue.map(item => ({
                id: item.id,
                path: item.path,
                method: item.method,
                retries: item.retries,
                timestamp: item.timestamp
            }))
        }
    }
}

// Export singleton instance
export const apiQueue = new ApiQueueManager()
export default apiQueue
