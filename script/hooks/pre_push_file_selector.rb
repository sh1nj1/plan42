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
    existing_paths(candidates)
  end

  private

  def test_candidates(path)
    prefix, relative_path, engine_name = split_engine_path(path)
    test_root = "#{prefix}test"
    return [ path ] if path.match?(%r{(?:^|/)test/.+_test\.rb\z})
    return shared_test_roots(prefix, test_root, relative_path) if shared_test_infrastructure?(relative_path)
    return hook_tests(relative_path) if relative_path.start_with?("script/hooks/")
    return [ "test/lib/kamal_deploy_config_test.rb" ] if relative_path == "config/deploy.yml"

    case relative_path
    when %r{\Aapp/(.+)\.rb\z}
      app_path = Regexp.last_match(1)
      candidates = [ "#{test_root}/#{app_path}_test.rb" ]
      path_parts = app_path.split("/")
      if path_parts[1] == engine_name
        path_parts.delete_at(1)
        candidates << "#{test_root}/#{path_parts.join('/')}_test.rb"
      end
      if path_parts[1] == "concerns" && path_parts[2] == engine_name
        path_parts.delete_at(1)
        candidates << "#{test_root}/#{path_parts.join('/')}_test.rb"
      end
      include_test_variants(candidates)
    when %r{\Aapp/views/(.+)/(_?[^/]+?)(?:\.[^.]+)*\.erb\z}
      view_path = Regexp.last_match(1)
      template_name = Regexp.last_match(2).delete_prefix("_")
      [ "#{test_root}/views/#{view_path}/#{template_name}_test.rb" ]
    when %r{\Alib/tasks/(.+)\.rake\z}
      [ "#{test_root}/lib/#{Regexp.last_match(1)}_task_test.rb" ]
    when %r{\Alib/(.+)\.rb\z}
      lib_path = Regexp.last_match(1)
      candidates = [ "#{test_root}/lib/#{lib_path}_test.rb" ]
      path_parts = lib_path.split("/")
      if path_parts.first == engine_name
        path_parts.shift
        candidates << "#{test_root}/lib/#{path_parts.join('/')}_test.rb"
      end
      candidates
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

  def shared_test_infrastructure?(path)
    path == "test/test_helper.rb" || path.start_with?("test/support/", "test/fixtures/")
  end

  def hook_tests(path)
    tests = [ "test/lib/pre_push_hook_test.rb" ]
    tests << "test/lib/pre_push_file_selector_test.rb" if path.end_with?("pre_push_file_selector.rb")
    tests
  end

  def shared_test_roots(prefix, test_root, relative_path)
    return all_test_roots if prefix.empty? || relative_path.start_with?("test/fixtures/")

    [ test_root ]
  end

  def all_test_roots
    engine_test_roots = Dir.glob(File.join(@root, "engines/*/test"))
      .select { |path| File.directory?(path) }
      .map { |path| path.delete_prefix("#{@root}/") }

    [ "test", *engine_test_roots ]
  end

  def include_test_variants(paths)
    paths.flat_map do |path|
      pattern = path.sub(/_test\.rb\z/, "_*_test.rb")
      variants = Dir.glob(File.join(@root, pattern)).map { |file| file.delete_prefix("#{@root}/") }
      [ path, *variants ]
    end
  end

  def existing_paths(paths)
    paths.uniq.sort.select { |path| File.exist?(File.join(@root, path)) }
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
