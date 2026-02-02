#!/usr/bin/env ruby
# frozen_string_literal: true

# Check that all i18n keys exist in both en.yml and ko.yml

require "yaml"

# Rails/gem-provided keys to ignore (these come from rails-i18n gem)
IGNORED_PREFIXES = %w[
  date
  datetime
  time
  number
  support
  activerecord.errors.messages
  errors.messages
  helpers.select
].freeze

def flatten_keys(hash, prefix = "")
  keys = []
  hash.each do |key, value|
    full_key = prefix.empty? ? key.to_s : "#{prefix}.#{key}"
    if value.is_a?(Hash)
      keys.concat(flatten_keys(value, full_key))
    else
      keys << full_key
    end
  end
  keys
end

def ignored_key?(key)
  IGNORED_PREFIXES.any? { |prefix| key.start_with?(prefix) }
end

def load_locale_keys(locale)
  keys = []
  Dir.glob("config/locales/**/*.#{locale}.yml").each do |file|
    yaml = YAML.load_file(file)
    next unless yaml && yaml[locale]

    keys.concat(flatten_keys(yaml[locale]))
  end
  keys.reject { |k| ignored_key?(k) }.uniq.sort
end

en_keys = load_locale_keys("en")
ko_keys = load_locale_keys("ko")

missing_in_ko = en_keys - ko_keys
missing_in_en = ko_keys - en_keys

has_errors = false

if missing_in_ko.any?
  puts "\n\e[31m❌ Keys missing in Korean (ko.yml):\e[0m"
  missing_in_ko.each { |key| puts "  - #{key}" }
  has_errors = true
end

if missing_in_en.any?
  puts "\n\e[31m❌ Keys missing in English (en.yml):\e[0m"
  missing_in_en.each { |key| puts "  - #{key}" }
  has_errors = true
end

if has_errors
  puts "\n\e[33mTotal: #{missing_in_ko.size} missing in ko, #{missing_in_en.size} missing in en\e[0m"
  exit 1
else
  puts "\e[32m✓ All i18n keys are present in both en and ko\e[0m"
  exit 0
end
