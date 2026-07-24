Rails::HTML4::SafeListSanitizer.allowed_attributes.add "style"
if defined?(Rails::HTML5::SafeListSanitizer)
  Rails::HTML5::SafeListSanitizer.allowed_attributes.add "style"
end

# Allow CSS var() function in sanitized HTML so that design-token-based
# inline styles (e.g. color: var(--color-danger)) survive sanitization.
Loofah::HTML5::SafeList::ALLOWED_CSS_FUNCTIONS.add("var")
