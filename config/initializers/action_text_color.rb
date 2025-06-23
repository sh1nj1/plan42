Rails::HTML4::SafeListSanitizer.allowed_attributes.add "style"
if defined?(Rails::HTML5::SafeListSanitizer)
  Rails::HTML5::SafeListSanitizer.allowed_attributes.add "style"
end
