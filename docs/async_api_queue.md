# Async API Queue for Inline Editor

## Overview
The Async API Queue is a robust mechanism designed to handle creative updates in the inline editor asynchronously. It replaces the previous blocking save mechanism, providing a smoother user experience, offline support, and better data integrity.

## Key Features

### 1. Asynchronous Processing
- **Non-blocking UI**: User actions (like moving items or typing) are no longer blocked by network requests.
- **Sequential Execution**: Requests are processed one by one to ensure data consistency (e.g., a "move" operation must complete before a subsequent "edit").

### 2. Robust Persistence
- **LocalStorage**: The queue is persisted to `localStorage`, ensuring that pending changes are not lost if the browser is closed or reloaded.
- **User Scoping**: The storage key is scoped to the current user (e.g., `api_queue_123`) to prevent data leakage between different users on the same device.

### 3. Offline Support
- **Network Detection**: The queue automatically pauses when the network goes offline and resumes when online.
- **Retry Logic**: Failed requests are retried up to 3 times before being marked as permanently failed.

### 4. Deduplication & Optimization
- **Request Merging**: Multiple updates to the same creative (e.g., rapid typing) are merged into a single request using a `dedupeKey`.
- **Callback Preservation**: `onSuccess` callbacks from merged requests are chained, ensuring all UI updates (like removing a row after a move) still occur.

## Architecture

### `ApiQueueManager` (`app/javascript/lib/api/queue_manager.js`)
The core class managing the queue. It is a singleton instance exported as `apiQueue`.

- **`enqueue(request)`**: Adds a request to the queue. Handles deduplication and merging.
- **`processQueue()`**: Asynchronously processes items in the queue.
- **`initialize(userId)`**: Sets the storage key based on the user ID and loads persisted items.
- **`removeByDedupeKey(key)`**: Allows cancelling pending requests (used when deleting a creative to prevent 404s).

### Integration (`app/javascript/creative_row_editor.js`)
The inline editor integrates with the queue for all state-changing operations.

- **Initialization**: Calls `apiQueue.initialize(currentUserId)` and `apiQueue.start()` on `turbo:load`.
- **Saving**: `saveForm` now enqueues requests instead of calling `fetch` directly.
- **Deletion**: `deleteCurrent` removes any pending saves for the creative before destroying it to prevent race conditions.
- **Error Handling**: Listens for `api-queue-request-failed` to alert the user (suppressing 404s for deleted items).

## Data Structure

### Queue Item
```javascript
{
  id: "timestamp_random",
  path: "/creatives/123",
  method: "PATCH",
  body: FormData, // Serialized for storage
  dedupeKey: "creative_123",
  retries: 0,
  timestamp: 1234567890
}
```

### Storage Keys
- `api_queue_{userId}`: Active queue items.
- `api_queue_{userId}_failed`: Permanently failed items (for debugging/recovery).

## Testing

### Unit Tests (Jest)
Located in `app/javascript/lib/api/__tests__/queue_manager.test.js`.
- Verifies queue persistence, deduplication, retry logic, and FormData handling.
- Run with: `npm test`

### System Tests (Rails)
Located in `test/system/creative_inline_edit_test.rb` and `test/system/creative_upload_race_test.rb`.
- Verifies end-to-end functionality, including UI responsiveness and data persistence.
- Run with: `rails test test/system/creative_inline_edit_test.rb`
