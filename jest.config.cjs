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
  ]
}
