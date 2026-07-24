module.exports = {
  testEnvironment: "./jest.environment.cjs",
  extensionsToTreatAsEsm: [".jsx"],
  moduleFileExtensions: ["js", "jsx", "json"],
  transform: {},
  testMatch: ["**/__tests__/**/*.test.[jt]s?(x)"],
  roots: [
    "<rootDir>/app/javascript",
    "<rootDir>/engines",
    // Served production JS outside app/javascript (PWA service worker). Needed so
    // Jest's file crawler discovers it for coverage; no tests live here.
    "<rootDir>/app/views/pwa"
  ],
  moduleDirectories: [
    "node_modules",
    "app/javascript"
  ],
  // Coverage is collected only when run with --coverage (see `npm run test:coverage`).
  // NOTE: `.jsx` is intentionally excluded. Tests run as native ESM (`transform: {}`)
  // and the bundle is built with esbuild, so no JSX-aware transform is registered;
  // istanbul cannot parse JSX and would emit noisy parse errors. The `.jsx` React
  // components are currently untested — including them would require a JSX-aware
  // coverage transform. Tracked as a follow-up.
  collectCoverageFrom: [
    "app/javascript/**/*.js",
    "engines/*/app/javascript/**/*.js",
    // Served production JS that lives outside app/javascript: the PWA service
    // worker is delivered via `rails/pwa#service_worker` (config/routes.rb) and
    // registered at runtime by register_service_worker.js. No test imports it,
    // so without this glob it is absent from the report instead of counted at 0%.
    "app/views/pwa/**/*.js",
    "!**/__tests__/**",
    "!**/node_modules/**"
  ],
  coverageDirectory: "coverage/js",
  // lcov -> Codecov upload; json-summary -> machine-readable totals for the CI
  // job summary; text-summary -> human-readable console output.
  coverageReporters: ["text-summary", "text", "lcov", "json-summary"]
}
