/** @type {import('stylelint').Config} */
export default {
  extends: ['stylelint-config-standard'],
  rules: {
    // Enforce design tokens — warn on hardcoded values
    // These are warnings (not errors) to allow gradual migration
    'declaration-property-value-no-unknown': null,

    // Disallow hardcoded colors (hex, rgb, hsl) in most properties
    // Exceptions: design_tokens.css, dark_mode.css where tokens are defined
    'color-no-hex': [true, {
      severity: 'warning',
      message: 'Use a design token (e.g. var(--color-*)) instead of hardcoded hex color',
    }],

    // Allow CSS custom properties
    'custom-property-pattern': null,

    // Allow class naming patterns (BEM, etc.)
    'selector-class-pattern': null,

    // Allow @import
    'import-notation': null,

    // Relaxed rules for gradual migration of existing code
    'no-descending-specificity': null,
    'declaration-block-no-redundant-longhand-properties': null,
    'shorthand-property-no-redundant-values': null,
    'alpha-value-notation': null,
    'color-function-notation': null,
    'color-function-alias-notation': [true, { severity: 'warning' }],
    'declaration-property-value-keyword-no-deprecated': [true, { severity: 'warning' }],
    'comment-empty-line-before': null,
    'media-feature-range-notation': null,
    'length-zero-no-unit': null,
    'selector-attribute-quotes': null,
    'rule-empty-line-before': null,
    'value-keyword-case': null,
    'no-duplicate-selectors': [true, { severity: 'warning' }],
    'declaration-block-no-duplicate-properties': [true, { severity: 'warning' }],
    'color-hex-length': null,
  },
  ignoreFiles: [
    '**/node_modules/**',
    '**/vendor/**',
    '**/design_tokens.css',   // Token definitions can use raw values
    '**/dark_mode.css',       // Theme definitions can use raw values
  ],
};
