# frozen_string_literal: true

require "find"

module Collavre
  # Read-only window onto the running application's own source code, so an
  # agent can answer "how does Collavre do X" from the code that is actually
  # deployed rather than from memory. The running app's root IS the released
  # version (the Docker image ships it), so no download is needed.
  #
  # Everything goes through an allowlist: only application code, locales,
  # routes and docs are visible. Paths are resolved with realpath before the
  # check, so `..` segments and symlinks cannot escape the allowlist, and a
  # denylist is applied on top so secrets are never readable even if a future
  # allowlist entry happens to contain them.
  class SourceBrowser
    class AccessDenied < StandardError; end

    ALLOWED_PATTERNS = %w[
      app
      config/locales
      config/routes.rb
      docs
      engines/*/app
      engines/*/lib
      engines/*/config/locales
      engines/*/config/routes.rb
    ].freeze

    DENIED_SEGMENTS = %w[storage log tmp node_modules .kamal .git].freeze
    DENIED_BASENAME_PATTERNS = [
      /\A\.env/,
      /\.key\z/,
      /\Acredentials/,
      /\Adeploy.*\.ya?ml\z/,
      /\Amaster\.key\z/
    ].freeze

    MAX_FILE_BYTES = 200_000
    MAX_READ_LINES = 400
    MAX_LIST_ENTRIES = 500
    MAX_SEARCH_RESULTS = 100
    MAX_SEARCH_FILES = 5_000

    def self.root
      Rails.root
    end

    def initialize(root: self.class.root)
      @root = Pathname.new(File.realpath(root.to_s))
    end

    attr_reader :root

    # Top-level allowed roots, or the entries of one allowed directory.
    def list(path = nil)
      return { path: "", entries: allowed_roots.map { |p| entry_for(p) } } if path.blank?

      dir = resolve!(path)
      raise AccessDenied, "Not a directory: #{path}" unless dir.directory?

      children = dir.children.sort.reject { |child| denied?(child) || !child.exist? }
      entries = children.first(MAX_LIST_ENTRIES).map { |child| entry_for(child) }
      { path: relative(dir), entries: entries, truncated: children.size > MAX_LIST_ENTRIES }
    end

    # Lines of one text file, 1-indexed and inclusive.
    def read(path, start_line: 1, end_line: nil)
      file = resolve!(path)
      raise AccessDenied, "Not a file: #{path}" unless file.file?
      raise AccessDenied, "File too large: #{path}" if file.size > MAX_FILE_BYTES

      lines = text_lines(file)
      raise AccessDenied, "Binary file: #{path}" unless lines

      first = [ start_line.to_i, 1 ].max
      last = [ (end_line || (first + MAX_READ_LINES - 1)).to_i, first + MAX_READ_LINES - 1, lines.size ].min
      {
        path: relative(file),
        start_line: first,
        end_line: last,
        total_lines: lines.size,
        content: lines[(first - 1)..(last - 1)].to_a.each_with_index.map { |l, i| "#{first + i}: #{l}" }.join
      }
    end

    # Case-insensitive literal search across allowed text files.
    def search(query, path: nil)
      raise ArgumentError, "query is required" if query.to_s.strip.empty?

      needle = query.to_s.downcase
      matches = []
      files_scanned = 0
      each_file(path) do |file|
        break if matches.size >= MAX_SEARCH_RESULTS || files_scanned >= MAX_SEARCH_FILES

        files_scanned += 1
        (text_lines(file) || []).each_with_index do |line, idx|
          next unless line.downcase.include?(needle)

          matches << { path: relative(file), line: idx + 1, text: line.strip[0, 300] }
          break if matches.size >= MAX_SEARCH_RESULTS
        end
      end
      { query: query, matches: matches, truncated: matches.size >= MAX_SEARCH_RESULTS }
    end

    private

    def allowed_roots
      @allowed_roots ||= ALLOWED_PATTERNS.flat_map { |pattern| Dir.glob(root.join(pattern).to_s) }
                                         .map { |p| Pathname.new(File.realpath(p)) }
                                         .select { |p| within_root?(p) }
                                         .uniq.sort
    end

    def resolve!(path)
      candidate = root.join(path.to_s.delete_prefix("/"))
      # One message for "missing" and "forbidden", so probing cannot reveal
      # which files exist outside the allowlist.
      denied = "Not found or not readable: #{path}"
      raise AccessDenied, denied unless candidate.exist?

      real = Pathname.new(File.realpath(candidate.to_s))
      raise AccessDenied, denied unless allowed?(real)

      real
    end

    def allowed?(real)
      within_root?(real) && !denied?(real) &&
        allowed_roots.any? { |allowed| real == allowed || real.to_s.start_with?("#{allowed}/") }
    end

    def within_root?(real)
      real.to_s.start_with?("#{root}/")
    end

    def denied?(path)
      rel = path.to_s.delete_prefix("#{root}/")
      segments = rel.split("/")
      return true if segments.intersect?(DENIED_SEGMENTS)

      base = segments.last.to_s
      DENIED_BASENAME_PATTERNS.any? { |pattern| base.match?(pattern) }
    end

    def each_file(path)
      bases = path.blank? ? allowed_roots : [ resolve!(path) ]
      bases.each do |base|
        if base.file?
          yield base
          next
        end
        Find.find(base.to_s) do |entry|
          pathname = Pathname.new(entry)
          if denied?(pathname) || pathname.symlink?
            Find.prune
          elsif pathname.file? && pathname.size <= MAX_FILE_BYTES
            yield pathname
          end
        end
      end
    end

    def text_lines(file)
      data = File.binread(file)
      return nil if data.include?("\x00")

      text = data.force_encoding(Encoding::UTF_8)
      return nil unless text.valid_encoding?

      text.lines
    end

    def entry_for(path)
      { path: relative(path), type: path.directory? ? "directory" : "file" }.tap do |entry|
        entry[:size] = path.size if path.file?
      end
    end

    def relative(path)
      path.to_s.delete_prefix("#{root}/")
    end
  end
end
