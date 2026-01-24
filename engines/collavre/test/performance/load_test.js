/*
 * How to run:
 * k6 run test/performance/load_test.js
 *
 * To run against a specific URL:
 * k6 run -e BASE_URL=https://target-url.com test/performance/load_test.js
 */

import http from 'k6/http';
import { check, sleep } from 'k6';

// Configuration: Ramp up to 20 virtual users (VUs) over 30 seconds
export let options = {
    stages: [
        { duration: '30s', target: 20 }, // Ramp up to 20 users over 30 seconds
        { duration: '1m', target: 20 },  // Stay at 20 users for 1 minute
        { duration: '30s', target: 0 },  // Ramp down to 0 users over 30 seconds
    ],
    thresholds: {
        http_req_duration: ['p(95)<500'], // 95% of requests must complete within 500ms
    },
};

const BASE_URL = __ENV.BASE_URL || 'http://localhost:3000';

export default function () {
    // 1. Access homepage (before login)
    let res = http.get(BASE_URL);

    check(res, {
        'status is 200 or 302': (r) => r.status === 200 || r.status === 302,
    });

    // You can add requests using cookies after login here.
    // const jar = http.cookieJar();
    // jar.set(BASE_URL, 'App-Session', 'YOUR_SESSION_COOKIE');

    sleep(1); // User think time (wait 1 second)
}
