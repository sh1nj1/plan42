/**
 * @jest-environment jsdom
 */
import { jest } from '@jest/globals';

// Mock csrfFetch using unstable_mockModule for ESM support
const mockCsrfFetch = jest.fn();
const mockRefreshCsrfToken = jest.fn().mockResolvedValue('fresh-token');
jest.unstable_mockModule('../csrf_fetch', () => ({
    __esModule: true,
    default: mockCsrfFetch,
    refreshCsrfToken: mockRefreshCsrfToken,
}));

// Dynamic imports are required when using unstable_mockModule
const { default: apiQueue } = await import('../queue_manager');
const { default: csrfFetch } = await import('../csrf_fetch');

describe('ApiQueueManager', () => {
    beforeEach(() => {
        apiQueue.clear();
        localStorage.clear();
        mockCsrfFetch.mockClear();
        mockRefreshCsrfToken.mockClear();
        // Reset processing state
        apiQueue.processing = false;
        // Mock processQueue to prevent auto-execution during enqueue tests
        jest.spyOn(apiQueue, 'processQueue').mockImplementation(async () => { });
        // Suppress console.error for expected errors
        jest.spyOn(console, 'error').mockImplementation(() => { });

        // Initialize with test user
        apiQueue.initialize('test_user');
    });

    afterEach(() => {
        jest.restoreAllMocks();
    });

    test('should deduplicate requests and merge callbacks', () => {
        const callback1 = jest.fn();
        const callback2 = jest.fn();

        // Enqueue first request
        apiQueue.enqueue({
            path: '/test',
            method: 'PATCH',
            dedupeKey: 'test_1',
            onSuccess: callback1
        });

        // Enqueue second request with same dedupeKey
        apiQueue.enqueue({
            path: '/test',
            method: 'PATCH',
            dedupeKey: 'test_1',
            onSuccess: callback2
        });

        expect(apiQueue.queue.length).toBe(1);

        // Execute the merged callback
        const item = apiQueue.queue[0];
        item.onSuccess();

        expect(callback1).toHaveBeenCalled();
        expect(callback2).toHaveBeenCalled();
    });

    test('should merge deletedAttachmentIds during deduplication', () => {
        apiQueue.enqueue({
            path: '/test',
            method: 'PATCH',
            dedupeKey: 'test_1',
            deletedAttachmentIds: [1, 2]
        });

        apiQueue.enqueue({
            path: '/test',
            method: 'PATCH',
            dedupeKey: 'test_1',
            deletedAttachmentIds: [2, 3]
        });

        expect(apiQueue.queue.length).toBe(1);
        expect(apiQueue.queue[0].deletedAttachmentIds).toEqual([1, 2, 3]);
    });

    test('should persist to localStorage without callbacks', () => {
        apiQueue.enqueue({
            path: '/test',
            onSuccess: () => { }
        });

        const stored = JSON.parse(localStorage.getItem('api_queue_test_user'));
        expect(stored).toHaveLength(1);
        expect(stored[0].onSuccess).toBeUndefined();
        expect(stored[0].path).toBe('/test');
    });

    test('should handle FormData correctly', async () => {
        // Restore processQueue for this test
        apiQueue.processQueue.mockRestore();

        const formData = new FormData();
        formData.append('file', 'test');

        // Mock successful response
        mockCsrfFetch.mockResolvedValue({ ok: true });

        const item = {
            path: '/upload',
            method: 'POST',
            body: formData
        };

        // We can call executeRequest directly to test it
        await apiQueue.executeRequest(item);

        expect(mockCsrfFetch).toHaveBeenCalled();
        const callArgs = mockCsrfFetch.mock.calls[0];
        const options = callArgs[1];

        expect(options.body).toBeInstanceOf(FormData);
        expect(options.body.has('file')).toBe(true);
    });

    test('should pass parsed JSON response data to onSuccess callback', async () => {
        // Restore processQueue for this test
        apiQueue.processQueue.mockRestore();

        const callback = jest.fn();

        // Mock successful response with JSON body containing markdown_source rewrite
        const rewrittenSource = '![img](/rails/active_storage/blobs/abc/image.png)';
        mockCsrfFetch.mockResolvedValue({
            ok: true,
            text: async () => JSON.stringify({ id: 42, markdown_source: rewrittenSource })
        });

        const item = {
            path: '/creatives/42',
            method: 'PATCH',
            onSuccess: callback,
            retries: 0
        };

        apiQueue.queue = [item];
        await apiQueue.processQueue();

        expect(callback).toHaveBeenCalledTimes(1);
        expect(callback).toHaveBeenCalledWith({ id: 42, markdown_source: rewrittenSource });
    });

    test('should dispatch event on permanent failure', async () => {
        // Restore processQueue for this test
        apiQueue.processQueue.mockRestore();

        const eventSpy = jest.spyOn(window, 'dispatchEvent');

        // Mock failed response
        mockCsrfFetch.mockRejectedValue(new Error('Network Error'));

        const item = {
            path: '/fail',
            retries: 3 // Max retries
        };

        // Manually add to queue to bypass enqueue logic
        apiQueue.queue = [item];

        await apiQueue.processQueue();

        expect(eventSpy).toHaveBeenCalledWith(expect.objectContaining({
            type: 'api-queue-request-failed'
        }));

        const failedItems = JSON.parse(localStorage.getItem('api_queue_test_user_failed'));
        expect(failedItems).toHaveLength(1);
        expect(failedItems[0].path).toBe('/fail');
        expect(failedItems[0].failedAt).toBeDefined();
    });

    test('executeRequest throws an ApiError carrying the server error payload', async () => {
        mockCsrfFetch.mockResolvedValue({
            ok: false,
            status: 422,
            statusText: 'Unprocessable Entity',
            text: async () => JSON.stringify({
                errors: ['Description cannot be changed directly for GitHub synced content'],
            }),
        });

        await expect(apiQueue.executeRequest({ path: '/creatives/42', method: 'PATCH' }))
            .rejects.toMatchObject({
                status: 422,
                errors: ['Description cannot be changed directly for GitHub synced content'],
                message: 'Description cannot be changed directly for GitHub synced content',
            });
    });

    test('does not retry non-retryable client errors (422)', async () => {
        apiQueue.processQueue.mockRestore();

        const eventSpy = jest.spyOn(window, 'dispatchEvent');

        // A 422 validation error will never succeed on retry — it must fail fast.
        mockCsrfFetch.mockResolvedValue({
            ok: false,
            status: 422,
            statusText: 'Unprocessable Entity',
            text: async () => JSON.stringify({ errors: ['Cannot do that'] }),
        });

        const item = { path: '/creatives/42', method: 'PATCH', retries: 0 };
        apiQueue.queue = [item];

        await apiQueue.processQueue();

        // Exactly one attempt — no retries.
        expect(mockCsrfFetch).toHaveBeenCalledTimes(1);

        const failureEvent = eventSpy.mock.calls
            .map(([event]) => event)
            .find((event) => event.type === 'api-queue-request-failed');
        expect(failureEvent).toBeDefined();
        expect(failureEvent.detail.error.errors).toEqual(['Cannot do that']);

        const failedItems = JSON.parse(localStorage.getItem('api_queue_test_user_failed'));
        expect(failedItems).toHaveLength(1);
    });

    test('refreshes the CSRF token and retries a payload-less 422 (stale token)', async () => {
        apiQueue.processQueue.mockRestore();

        // A stale CSRF token (e.g. after the tab was backgrounded) returns 422
        // with no error payload — unlike a validation 422, it is recoverable by
        // refreshing the token and retrying.
        mockCsrfFetch
            .mockResolvedValueOnce({
                ok: false,
                status: 422,
                statusText: 'Unprocessable Entity',
                text: async () => '',
            })
            .mockResolvedValueOnce({
                ok: true,
                status: 200,
                text: async () => JSON.stringify({ id: 42 }),
            });

        const onSuccess = jest.fn();
        const item = { path: '/creatives/42', method: 'PATCH', retries: 0, onSuccess };
        apiQueue.queue = [item];

        await apiQueue.processQueue();

        // Token refreshed once, then the request retried and succeeded.
        expect(mockRefreshCsrfToken).toHaveBeenCalledTimes(1);
        expect(mockCsrfFetch).toHaveBeenCalledTimes(2);
        expect(onSuccess).toHaveBeenCalled();
        expect(apiQueue.queue).toHaveLength(0);

        const stored = localStorage.getItem('api_queue_test_user_failed');
        expect(stored ? JSON.parse(stored) : []).toHaveLength(0);
    });
});

describe('ordered creative saves', () => {
    beforeEach(() => {
        apiQueue.processing = false
        apiQueue.clear()
        mockCsrfFetch.mockReset()
        jest.spyOn(console, 'error').mockImplementation(() => {})
    })
    afterEach(() => jest.restoreAllMocks())

    test('merges partial updates without losing an unacknowledged progress change', () => {
        jest.spyOn(apiQueue, 'processQueue').mockImplementation(() => {})
        apiQueue.enqueue({ method: 'PATCH', path: '/creatives/42', dedupeKey: 'creative_42', body: { progress: 1, description: 'first' } })
        apiQueue.enqueue({ method: 'PATCH', path: '/creatives/42', dedupeKey: 'creative_42', body: { description: 'second' } })
        expect(apiQueue.queue[0].body).toEqual({ progress: 1, description: 'second' })
        expect(JSON.parse(localStorage.getItem(apiQueue.storageKey))[0].body).toEqual(apiQueue.queue[0].body)
    })

    test('retries the older save before sending the newer save and resolves dependent operations last', async () => {
        const pause = jest.spyOn(apiQueue, 'processQueue').mockImplementation(() => {})
        apiQueue.enqueue({ method: 'PATCH', path: '/creatives/42', dedupeKey: 'creative_42', body: { description: 'first' } })
        apiQueue.processing = true
        apiQueue.enqueue({ method: 'PATCH', path: '/creatives/42', dedupeKey: 'creative_42', body: { description: 'second' } })
        apiQueue.processing = false
        pause.mockRestore()
        const acknowledged = jest.fn()
        const waiting = apiQueue.waitFor('creative_42').then(acknowledged)
        expect(acknowledged).not.toHaveBeenCalled()
        mockCsrfFetch.mockRejectedValueOnce(new Error('temporary failure')).mockResolvedValue({ ok: true })
        await apiQueue.processQueue()
        await waiting
        expect(mockCsrfFetch.mock.calls.map(([, options]) => options.body.get('description'))).toEqual(['first', 'first', 'second'])
        expect(acknowledged).toHaveBeenCalledTimes(1)
        await expect(apiQueue.waitFor('creative_42')).resolves.toBeUndefined()
    })

    test('rejects dependent operations when the save fails validation', async () => {
        const pause = jest.spyOn(apiQueue, 'processQueue').mockImplementation(() => {})
        apiQueue.enqueue({ method: 'PATCH', path: '/creatives/42', dedupeKey: 'creative_42', body: { description: 'invalid' } })
        pause.mockRestore()
        const waiting = expect(apiQueue.waitFor('creative_42')).rejects.toMatchObject({ status: 403 })
        mockCsrfFetch.mockResolvedValue({ ok: false, status: 403, clone: () => ({ json: async () => ({ errors: ['Denied'] }) }) })
        await apiQueue.processQueue()
        await waiting
        expect(apiQueue.failedItems).toHaveLength(1)
    })

    test('rejects enqueue without replacing the previous draft when local storage is full', () => {
        jest.spyOn(apiQueue, 'processQueue').mockImplementation(() => {})
        apiQueue.enqueue({ path: '/creatives/42', dedupeKey: 'creative_42', body: { description: 'first' } })
        jest.spyOn(Storage.prototype, 'setItem').mockImplementation(() => { throw new Error('quota') })
        expect(() => apiQueue.enqueue({ path: '/creatives/42', dedupeKey: 'creative_42', body: { description: 'second' } })).toThrow('quota')
        expect(apiQueue.queue[0].body.description).toBe('first')
    })
})
