/**
 * @jest-environment jsdom
 */
import { jest } from '@jest/globals';

// Mock csrfFetch using unstable_mockModule for ESM support
const mockCsrfFetch = jest.fn();
jest.unstable_mockModule('../csrf_fetch', () => ({
    __esModule: true,
    default: mockCsrfFetch
}));

// Dynamic imports are required when using unstable_mockModule
const { default: apiQueue } = await import('../queue_manager');
const { default: csrfFetch } = await import('../csrf_fetch');

describe('ApiQueueManager', () => {
    beforeEach(() => {
        apiQueue.clear();
        localStorage.clear();
        mockCsrfFetch.mockClear();
        // Reset processing state
        apiQueue.processing = false;
        // Mock processQueue to prevent auto-execution during enqueue tests
        jest.spyOn(apiQueue, 'processQueue').mockImplementation(async () => { });
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

        const stored = JSON.parse(localStorage.getItem('api_queue'));
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
    });
});
