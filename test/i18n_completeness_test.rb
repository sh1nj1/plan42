require "test_helper"

class I18nCompletenessTest < ActiveSupport::TestCase
  # Patterns to extract translation keys from code
  T_CALL_PATTERNS = [
    /\bt\(['"]([^'"]+)['"]/,                    # t('key') or t("key")
    /\bI18n\.t\(['"]([^'"]+)['"]/,              # I18n.t('key') or I18n.t("key")
    /\bt\("([^"]+)"\s*,/,                       # t("key", ...)
    /\bI18n\.t\("([^"]+)"\s*,/                  # I18n.t("key", ...)
  ].freeze

  # Directories to scan for translation keys
  SCAN_DIRECTORIES = [
    Rails.root.join("app"),
    Rails.root.join("engines/collavre/app"),
    Rails.root.join("config/initializers")
  ].freeze

  # File extensions to scan
  FILE_EXTENSIONS = %w[.rb .erb .html.erb].freeze

  # Keys to ignore (dynamic keys, Rails built-ins, etc.)
  IGNORED_KEY_PATTERNS = [
    /^activerecord\./,
    /^activemodel\./,
    /^errors\./,
    /^helpers\./,
    /^number\./,
    /^date\./,
    /^time\./,
    /^datetime\./,
    /^support\./,
    /^views\./
  ].freeze

  # Locales to verify
  LOCALES = %i[en ko].freeze

  test "all translation keys used in code are defined" do
    missing_keys = {}

    LOCALES.each do |locale|
      missing = find_missing_keys_for_locale(locale)
      missing_keys[locale] = missing if missing.any?
    end

    if missing_keys.any?
      message = build_error_message(missing_keys)
      flunk message
    else
      assert true, "All translation keys are defined"
    end
  end

  test "engine translation keys have collavre namespace prefix" do
    engine_files = collect_files([ Rails.root.join("engines/collavre/app") ])
    keys_without_prefix = []

    engine_files.each do |file|
      content = File.read(file)
      extract_translation_keys(content).each do |key|
        # Skip if it's a dynamic key or app. prefix (shared keys)
        next if key.include?('#{')
        next if key.start_with?("app.")
        next if key.start_with?("common.")
        next if key.start_with?("collavre.")
        next if key.start_with?(".")           # Relative keys (Rails lazy lookup)
        next if key.start_with?("admin.")      # Main app admin translations
        next if key.start_with?("doorkeeper.") # Main app doorkeeper translations
        next if ignored_key?(key)

        keys_without_prefix << { file: file.to_s.sub(Rails.root.to_s + "/", ""), key: key }
      end
    end

    if keys_without_prefix.any?
      message = "Engine files using translation keys without 'collavre.' prefix:\n"
      keys_without_prefix.group_by { |k| k[:file] }.each do |file, keys|
        message += "\n#{file}:\n"
        keys.each { |k| message += "  - #{k[:key]}\n" }
      end
      flunk message
    else
      assert true, "All engine translation keys have 'collavre.' prefix"
    end
  end

  private

  def find_missing_keys_for_locale(locale)
    all_keys = collect_all_translation_keys
    missing = []

    all_keys.each do |key_info|
      key = key_info[:key]
      file = key_info[:file]
      next if ignored_key?(key)
      next if key.include?('#{')  # Skip dynamic keys

      # Resolve relative keys (Rails lazy lookup) to full paths
      resolved_key = resolve_key(key, file)
      next unless resolved_key  # Skip if we can't resolve

      unless translation_exists?(resolved_key, locale)
        missing << { key: resolved_key, file: file }
      end
    end

    missing.uniq { |k| k[:key] }
  end

  # Resolve relative keys based on file path
  def resolve_key(key, file)
    return key unless key.start_with?(".")

    # Extract view path for Rails lazy lookup
    # e.g., engines/collavre/app/views/collavre/creatives/index.html.erb -> collavre.creatives.index
    if file =~ %r{engines/collavre/app/views/collavre/(.+?)(?:\.html)?\.erb$}
      view_path = $1.gsub("/", ".").sub(/^_/, "").gsub(/\._/, ".")
      "collavre.#{view_path}#{key}"
    elsif file =~ %r{app/views/(.+?)(?:\.html)?\.erb$}
      view_path = $1.gsub("/", ".").sub(/^_/, "").gsub(/\._/, ".")
      "#{view_path}#{key}"
    else
      nil  # Can't resolve - skip this key
    end
  end

  def collect_all_translation_keys
    keys = []
    files = collect_files(SCAN_DIRECTORIES)

    files.each do |file|
      content = File.read(file)
      extract_translation_keys(content).each do |key|
        keys << { key: key, file: file.to_s.sub(Rails.root.to_s + "/", "") }
      end
    end

    keys
  end

  def collect_files(directories)
    files = []
    directories.each do |dir|
      next unless dir.exist?
      Dir.glob(dir.join("**/*")).each do |file|
        next unless File.file?(file)
        next unless FILE_EXTENSIONS.any? { |ext| file.end_with?(ext) }
        files << Pathname.new(file)
      end
    end
    files
  end

  def extract_translation_keys(content)
    keys = []
    T_CALL_PATTERNS.each do |pattern|
      content.scan(pattern).flatten.each do |key|
        keys << key if key.present?
      end
    end
    keys.uniq
  end

  def translation_exists?(key, locale)
    I18n.exists?(key, locale)
  rescue
    false
  end

  def ignored_key?(key)
    IGNORED_KEY_PATTERNS.any? { |pattern| key.match?(pattern) }
  end

  def build_error_message(missing_keys)
    message = "Missing translation keys:\n"

    missing_keys.each do |locale, keys|
      message += "\n=== Locale: #{locale} ===\n"
      keys.group_by { |k| k[:file] }.each do |file, file_keys|
        message += "\n#{file}:\n"
        file_keys.each { |k| message += "  - #{k[:key]}\n" }
      end
    end

    message
  end
end
