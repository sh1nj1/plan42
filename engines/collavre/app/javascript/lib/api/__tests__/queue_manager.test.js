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

    test('reloads a persisted draft before merging a subsequent edit', async () => {
        const { recoverFailedCreative, needsCreativeSaveRetry } = await import('../../../modules/failed_creative_save');
        apiQueue.enqueue({
            path: '/creatives/42', method: 'PATCH', dedupeKey: 'creative_42',
            body: { 'creative[description]': 'offline draft', 'creative[progress]': 1 },
            onSuccess: () => {},
        });
        apiQueue.initialize('test_user');
        const tree = document.createElement('div');
        const recovered = recoverFailedCreative(apiQueue, { id: 42, description: 'stale server', progress: 0 }, tree);
        expect(recovered.description).toBe('offline draft');
        expect(recovered.progress).toBe(1);
        expect(tree.dataset.saveState).toBe('pending');
        expect(needsCreativeSaveRetry(apiQueue, 42, tree)).toBe(true);
        apiQueue.enqueue({
            path: '/creatives/42', method: 'PATCH', dedupeKey: 'creative_42',
            body: { 'creative[description]': recovered.description + ' continued' },
        });
        expect(apiQueue.queue).toHaveLength(1);
        expect(apiQueue.queue[0].body).toEqual({
            'creative[description]': 'offline draft continued', 'creative[progress]': 1,
        });
    });

    test('invalidates stale rows when a persisted request completes before the editor opens', async () => {
        const { needsCreativeReconciliation, fetchReconciledCreative } = await import('../queue_reconciliation');
        apiQueue.enqueue({ path: '/creatives/42', method: 'PATCH', dedupeKey: 'creative_42',
            body: { 'creative[description]': 'persisted draft' }, onSuccess: () => {} });
        apiQueue.initialize('test_user');
        mockCsrfFetch.mockResolvedValue({ ok: true, text: async () => '{}' });
        apiQueue.processQueue.mockRestore();
        await apiQueue.processQueue();
        expect(apiQueue.queue).toEqual([]);
        expect(JSON.parse(localStorage.getItem(apiQueue.storageKey))).toEqual([]);
        const row = document.createElement('div');
        expect(needsCreativeReconciliation(apiQueue, 42, row)).toBe(true);
        // A Turbo session reinitializes the queue without replacing the JS singleton.
        apiQueue.initialize('test_user');
        expect(needsCreativeReconciliation(apiQueue, 42, row)).toBe(true);
        expect(await fetchReconciledCreative(apiQueue, 42, row, async () => ({ description: 'persisted draft' })))
            .toEqual({ description: 'persisted draft' });
        expect(needsCreativeReconciliation(apiQueue, 42, row)).toBe(false);
    });

    test.each(['failed', 'in-flight', 'reloaded'])('carries %s attachment cleanup into a successful replacement', async state => {
        const original = { path: '/creatives/42', method: 'PATCH', dedupeKey: 'creative_42', body: { description: 'draft' }, deletedAttachmentIds: [1, 2] };
        apiQueue.enqueue(original);
        if (state === 'failed') {
            apiQueue.failedItems = apiQueue.queue;
            apiQueue.queue = [];
            apiQueue.saveFailedToLocalStorage();
            apiQueue.saveToLocalStorage();
            apiQueue.initialize('test_user');
        } else if (state === 'in-flight') {
            apiQueue.processing = true;
        } else {
            apiQueue.initialize('test_user');
        }
        apiQueue.failedItems.push({ dedupeKey: 'other', deletedAttachmentIds: [99] });
        apiQueue.enqueue({ ...original, body: { description: 'continued' }, deletedAttachmentIds: [2, 3] });
        const replacement = apiQueue.queue.at(-1);
        expect(replacement.deletedAttachmentIds).toEqual([1, 2, 3]);
        if (state === 'in-flight') {
            expect(apiQueue.queue).toHaveLength(2);
            apiQueue.failedItems.push(apiQueue.queue.shift());
            apiQueue.processing = false;
        }
        const cleanup = jest.fn();
        window.addEventListener('api-queue-attachments-deleted', cleanup);
        mockCsrfFetch.mockResolvedValue({ ok: true, status: 200, json: async () => ({}) });
        apiQueue.processQueue.mockRestore();
        await apiQueue.processQueue();
        window.removeEventListener('api-queue-attachments-deleted', cleanup);
        expect(cleanup).toHaveBeenCalledTimes(1);
        expect(cleanup.mock.calls[0][0].detail.attachmentIds).toEqual([1, 2, 3]);
        expect(apiQueue.failedItems).toEqual([{ dedupeKey: 'other', deletedAttachmentIds: [99] }]);
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

    test('carries executing progress into a later save after permanent failure', async () => {
        const pause = jest.spyOn(apiQueue, 'processQueue').mockImplementation(() => {})
        apiQueue.enqueue({ method: 'PATCH', path: '/creatives/42', dedupeKey: 'creative_42', body: { progress: 1, description: 'first' } })
        const first = apiQueue.queue[0]
        apiQueue.processing = true
        apiQueue.enqueue({ method: 'PATCH', path: '/creatives/42', dedupeKey: 'creative_42', body: { description: 'second' } })
        expect(apiQueue.queue[0]).toBe(first)
        expect(apiQueue.queue[1].body).toEqual({ progress: 1, description: 'second' })
        apiQueue.processing = false
        pause.mockRestore()
        mockCsrfFetch.mockResolvedValueOnce({ ok: false, status: 403, clone: () => ({ json: async () => ({ errors: ['Denied'] }) }) }).mockResolvedValue({ ok: true })
        await apiQueue.processQueue()
        expect(mockCsrfFetch.mock.calls[1][1].body.get('progress')).toBe('1')
        expect(apiQueue.failedItems).toEqual([])
        expect(JSON.parse(localStorage.getItem(`${apiQueue.storageKey}_failed`))).toEqual([])
    })

    test('merges durable failed fields into retries while allowing a new value to win', () => {
        jest.spyOn(apiQueue, 'processQueue').mockImplementation(() => {})
        apiQueue.failedItems = [{ dedupeKey: 'creative_42', body: { progress: 1, description: 'failed' } }]
        apiQueue.saveFailedToLocalStorage()
        apiQueue.failedItems = []
        apiQueue.loadFailedFromLocalStorage()
        apiQueue.enqueue({ method: 'PATCH', path: '/creatives/42', dedupeKey: 'creative_42', body: { description: 'retry' } })
        expect(apiQueue.queue[0].body).toEqual({ progress: 1, description: 'retry' })
        apiQueue.enqueue({ method: 'PATCH', path: '/creatives/42', dedupeKey: 'creative_42', body: { progress: 0 } })
        expect(apiQueue.queue[0].body).toEqual({ progress: 0, description: 'retry' })
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
