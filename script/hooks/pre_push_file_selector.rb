#!/usr/bin/env ruby
# frozen_string_literal: true

class PrePushFileSelector
  RUBY_FILES = /(?:\.rb|\.rake|\.gemspec)\z|(?:^|\/)(?:Gemfile|Rakefile)\z/

  def initialize(root: Dir.pwd)
    @root = root
  end

  def rubocop_files(changed_files)
    existing_files(changed_files.grep(RUBY_FILES))
  end

  def test_files(changed_files)
    candidates = changed_files.flat_map { |path| test_candidates(path) }
    existing_files(candidates)
  end

  private

  def test_candidates(path)
    return [ path ] if path.match?(%r{(?:^|/)test/.+_test\.rb\z})

    prefix, relative_path, engine_name = split_engine_path(path)
    test_root = "#{prefix}test"

    case relative_path
    when %r{\Aapp/(.+)\.rb\z}
      app_path = Regexp.last_match(1)
      candidates = [ "#{test_root}/#{app_path}_test.rb" ]
      path_parts = app_path.split("/")
      if path_parts[1] == engine_name
        path_parts.delete_at(1)
        candidates << "#{test_root}/#{path_parts.join('/')}_test.rb"
      end
      candidates
    when %r{\Alib/(.+)\.rb\z}
      [ "#{test_root}/lib/#{Regexp.last_match(1)}_test.rb" ]
    when %r{\A(config|db)/(.+)\.rb\z}
      [ "#{test_root}/#{Regexp.last_match(1)}/#{Regexp.last_match(2)}_test.rb" ]
    else
      []
    end
  end

  def split_engine_path(path)
    match = path.match(%r{\A(engines/[^/]+/)(.+)\z})
    return [ "", path, nil ] unless match

    [ match[1], match[2], match[1].split("/")[1] ]
  end

  def existing_files(paths)
    paths.uniq.sort.select { |path| File.file?(File.join(@root, path)) }
  end
end

if $PROGRAM_NAME == __FILE__
  mode = ARGV.fetch(0, "")
  selector = PrePushFileSelector.new(root: File.expand_path("../..", __dir__))
  changed_files = $stdin.each_line(chomp: true).reject(&:empty?)

  selected_files = case mode
  when "rubocop"
    selector.rubocop_files(changed_files)
  when "tests"
    selector.test_files(changed_files)
  else
    abort "Usage: #{File.basename(__FILE__)} (rubocop|tests)"
  end

  puts selected_files
end
