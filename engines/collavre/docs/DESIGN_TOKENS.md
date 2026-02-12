# Design Tokens Guide

Collavre uses a semantic design token system based on [Open Props](https://open-props.style/) scales. All tokens are defined in the `collavre` core engine and consumed by host apps and dependent engines.

## Architecture

```
design_tokens.css   → Token definitions (primitive + semantic)
dark_mode.css       → Legacy aliases (backward compat)
stylelint.config    → Enforces token usage (color-no-hex = error)
```

**Rules:**
- Tokens are defined **only** in `collavre` core engine
- `collavre_*` engines and host app **consume only**
- Every semantic token must have light, `body.dark-mode`, and `prefers-color-scheme: dark` values
- Hardcoded hex colors are **lint errors** (use `/* stylelint-disable-line color-no-hex */` for intentional exceptions)

## Token Categories

### Spacing (`--space-*`)

| Token | Value | Use for |
|-------|-------|---------|
| `--space-1` | 4px | Tight gaps, icon padding |
| `--space-2` | 8px | Default gap, small padding |
| `--space-3` | 16px | Section padding, medium gaps |
| `--space-4` | 20px | Comfortable padding |
| `--space-5` | 24px | Large padding |
| `--space-7` | 32px | Section margins |
| `--space-8` | 48px | Page-level spacing |
| `--space-12` | 128px | Hero spacing |

### Typography

**Font Size (`--text-*`)**

| Token | Value | Use for |
|-------|-------|---------|
| `--text-00` | 8px | Tiny labels |
| `--text-0` | 12px | Captions, badges |
| `--text-1` | 16px | Body text (default) |
| `--text-3` | 20px | Subheadings |
| `--text-4` | 24px | Section headings |
| `--text-5` | 32px | Page titles |

**Font Weight (`--weight-*`)**

| Token | Value | Use for |
|-------|-------|---------|
| `--weight-4` | 400 | Normal body text |
| `--weight-5` | 500 | Medium emphasis |
| `--weight-6` | 600 | Semi-bold, labels |
| `--weight-7` | 700 | Bold headings |

### Border Radius (`--radius-*`)

| Token | Value | Use for |
|-------|-------|---------|
| `--radius-1` | 2px | Subtle rounding |
| `--radius-2` | 5px | Buttons, inputs |
| `--radius-3` | 1rem | Cards, panels |
| `--radius-round` | 1e5px | Pills, avatars |

### Shadows (`--shadow-*`)

| Token | Use for |
|-------|---------|
| `--shadow-1` | Subtle elevation (cards) |
| `--shadow-2` | Medium elevation (dropdowns) |
| `--shadow-3` | High elevation (modals) |
| `--shadow-4` | Maximum elevation (toasts) |

### Z-Index Layers (`--layer-*`)

| Token | Value | Use for |
|-------|-------|---------|
| `--layer-1` | 1 | Minor stacking |
| `--layer-2` to `--layer-5` | 2–5 | Incremental stacking |
| `--layer-popup` | 100 | Dropdowns, popovers |
| `--layer-modal` | 1000 | Modals, dialogs |
| `--layer-toast` | 2000 | Toast notifications |
| `--layer-important` | 2147483647 | Critical overlays |

### Easing (`--ease-*`)

| Token | Use for |
|-------|---------|
| `--ease-1` to `--ease-5` | Standard transitions |
| `--ease-in-1` to `--ease-in-5` | Enter animations |
| `--ease-out-1` to `--ease-out-5` | Exit animations |

## Semantic Color Tokens

These are the primary tokens for theming. Every token has light and dark mode values.

### Surfaces (backgrounds)

| Token | Light | Dark | Use for |
|-------|-------|------|---------|
| `--surface-bg` | `#f7f7f8` | `#212121` | Page background |
| `--surface-nav` | `#ffffff` | `#181818` | Navigation bar |
| `--surface-section` | `#ffffff` | `#181818` | Cards, panels |
| `--surface-input` | `#f7f7f8` | `#212121` | Form inputs |
| `--surface-btn` | `#f1f2f4` | `#333543` | Default buttons |
| `--surface-secondary` | `#ffffff` | `#181818` | Secondary panels |

### Text

| Token | Light | Dark | Use for |
|-------|-------|------|---------|
| `--text-primary` | `#202123` | `#eaeaea` | Main body text |
| `--text-muted` | `#666666` | `#aaaaaa` | Secondary text |
| `--text-on-btn` | `#202123` | `#eaeaea` | Button text |
| `--text-nav` | `#202123` | `#eaeaea` | Navigation text |
| `--text-nav-btn` | `#202123` | `#eaeaea` | Nav button text |
| `--text-chat-btn` | `#666666` | `#aaaaaa` | Chat action buttons |
| `--text-on-badge` | `white` | `white` | Badge text |
| `--text-input` | `#202123` | `#eaeaea` | Input field text |

### Interactive Colors

| Token | Light | Dark | Use for |
|-------|-------|------|---------|
| `--color-link` | `#185ABC` | `#185ABC` | Hyperlinks |
| `--color-brand` | `oklch(60% 0.4 145)` | `oklch(50% 0.4 145)` | Brand accent |
| `--color-active` | `#007bff` | `#6a9eff` | Active/selected state |
| `--color-danger` | `#dc3545` | — | Errors, destructive |
| `--color-success` | `oklch(60% 0.4 145)` | — | Success state |
| `--color-warning` | `#f59e0b` | — | Warnings |
| `--color-highlight` | `#ffff99` | `#665500` | Text highlight |
| `--color-badge-bg` | `red` | `red` | Notification badge |
| `--color-accent-border` | `#7bc4e4` | `#4a8aaa` | Active element border |
| `--color-accent-text` | `#03425f` | `#8ecfef` | Active element text |
| `--color-code-bg` | `#f6f8fa` | `#2d2d2d` | Code block background |
| `--color-code-text` | `#1f2328` | `#e0e0e0` | Code block text |

### Borders & Effects

| Token | Light | Dark | Use for |
|-------|-------|------|---------|
| `--border-color` | `#e0e0e0` | `#333333` | Default borders |
| `--border-drag-over` | `#e0e0e0` | `#383a40` | Drag target |
| `--border-drag-edge` | `#bbbbbb` | `#777777` | Drag edge |
| `--hover-brightness` | `90%` | `110%` | Hover filter |

### Layout

| Token | Value | Use for |
|-------|-------|---------|
| `--max-width` | `960px` | Content max width |
| `--paragraph-space` | `0.75rem` | Paragraph gap |

## Usage Examples

```css
/* ✅ Correct — use semantic tokens */
.card {
  background: var(--surface-section);
  color: var(--text-primary);
  border: 1px solid var(--border-color);
  border-radius: var(--radius-2);
  padding: var(--space-3);
  box-shadow: var(--shadow-1);
}

/* ✅ Correct — spacing tokens */
.stack {
  display: flex;
  flex-direction: column;
  gap: var(--space-2);
}

/* ❌ Wrong — hardcoded hex (will fail lint) */
.card {
  background: #ffffff;
  color: #333;
}

/* ⚠️ Exception — intentional hardcoded with disable comment */
.syntax-highlight {
  color: #6a737d; /* stylelint-disable-line color-no-hex -- syntax theme */
}
```

## Legacy Aliases

For backward compatibility, `dark_mode.css` maps old variable names to semantic tokens:

| Legacy | → | Semantic |
|--------|---|----------|
| `--color-bg` | → | `--surface-bg` |
| `--color-text` | → | `--text-primary` |
| `--color-border` | → | `--border-color` |
| `--color-muted` | → | `--text-muted` |
| `--color-section-bg` | → | `--surface-section` |
| `--color-accent` | → | `--color-active` |
| `--color-btn-bg` | → | `--surface-btn` |
| `--color-btn-text` | → | `--text-on-btn` |
| `--color-nav-bg` | → | `--surface-nav` |
| `--color-input-bg` | → | `--surface-input` |
| `--color-input-text` | → | `--text-input` |

These aliases allow existing CSS to keep working while migrating to semantic tokens. New code should always use semantic token names.

## Theme Generator

The `AutoThemeGenerator` service generates themes using semantic tokens. When a user creates a custom theme, the AI generates values for all semantic tokens, ensuring proper contrast ratios between text and surface pairs.

Existing themes with legacy variable names continue to work via the alias layer.
