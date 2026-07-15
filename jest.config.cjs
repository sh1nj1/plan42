module.exports = {
  testEnvironment: "./jest.environment.cjs",
  extensionsToTreatAsEsm: [".jsx"],
  moduleFileExtensions: ["js", "jsx", "json"],
  transform: {},
  testMatch: ["**/__tests__/**/*.test.[jt]s?(x)"],
  roots: [
    "<rootDir>/app/javascript",
    "<rootDir>/engines"
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
    "!**/__tests__/**",
    "!**/node_modules/**"
  ],
  coverageDirectory: "coverage/js",
  coverageReporters: ["text-summary", "text", "lcov"]
}
