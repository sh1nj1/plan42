#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "date"

class Release
  COLORS = {
    red: "\e[0;31m",
    green: "\e[0;32m",
    yellow: "\e[1;33m",
    blue: "\e[0;34m",
    reset: "\e[0m"
  }.freeze

  def initialize
    @project_root = File.expand_path("..", __dir__)
    @engines_dir = File.join(@project_root, "engines")
    @build_dir = File.join(@project_root, "build", "gems")
    @release_branch = "release/#{Time.now.strftime('%Y%m%d-%H%M%S')}"
    @engines = discover_engines
    @engine_versions = {}
    @changed_engines = []
  end

  def run
    Dir.chdir(@project_root)

    print_header
    check_prerequisites
    create_release_branch
    run_tests
    analyze_and_bump_versions
    commit_changes
    build_gems
    print_summary
  end

  private

  def discover_engines
    engines = Dir.glob(File.join(@engines_dir, "*", "*.gemspec")).map do |gemspec|
      File.basename(File.dirname(gemspec))
    end

    if engines.empty?
      error "No engines found in #{@engines_dir}"
      exit 1
    end

    info "Discovered engines: #{engines.join(', ')}"
    engines
  end

  def print_header
    puts colorize(:blue, "========================================")
    puts colorize(:blue, "  Collavre Engines Release Script")
    puts colorize(:blue, "========================================")
  end

  def check_prerequisites
    # Check we're on main
    current_branch = `git branch --show-current`.strip
    unless current_branch == "main"
      error "Must be on main branch (currently on: #{current_branch})"
      exit 1
    end

    # Check for uncommitted changes
    unless `git status --porcelain`.strip.empty?
      error "Uncommitted changes exist. Please commit or stash first."
      exit 1
    end

    # Pull latest
    warn "Pulling latest from main..."
    system("git pull origin main") || exit(1)
  end

  def create_release_branch
    puts
    success "[Step 0] Creating release branch: #{@release_branch}"
    system("git checkout -b #{@release_branch}") || exit(1)
  end

  def run_tests
    puts
    success "[Step 1] Running tests..."

    warn "Running npm test..."
    system("npm test") || exit(1)

    warn "Running rake test..."
    system("bundle exec rake test") || exit(1)

    warn "Running rake test:system..."
    system("bundle exec rake test:system") || exit(1)

    success "All tests passed!"
  end

  def analyze_and_bump_versions
    puts
    success "[Step 2] Analyzing changes and determining versions..."

    @engines.each do |engine|
      analyze_engine(engine)
    end
  end

  def analyze_engine(engine)
    engine_dir = File.join(@engines_dir, engine)
    version_file = File.join(engine_dir, "lib", engine, "version.rb")

    unless File.exist?(version_file)
      warn "#{engine}: version.rb not found, skipping"
      return
    end

    current_version = extract_version(version_file)
    last_version_commit = `git log -1 --format="%H" -- #{version_file} 2>/dev/null`.strip

    # Get commits since last version change
    commits = if last_version_commit.empty?
      `git log --oneline -- #{engine_dir} 2>/dev/null`.lines.first(20)
    else
      `git log --oneline #{last_version_commit}..HEAD -- #{engine_dir} 2>/dev/null`.lines
    end

    commits = commits.map(&:strip).reject(&:empty?)

    if commits.any?
      new_version = bump_patch_version(current_version)
      @engine_versions[engine] = new_version
      @changed_engines << engine

      puts colorize(:blue, "#{engine}:") + " #{current_version} -> " + colorize(:green, new_version)
      puts "  Changes since last release:"
      commits.each { |c| puts "    - #{c}" }

      update_version_file(engine, version_file, new_version)
      update_release_notes(engine, engine_dir, new_version, commits)
    else
      puts colorize(:yellow, "#{engine}:") + " No changes since last release (staying at #{current_version})"
    end
  end

  def extract_version(version_file)
    content = File.read(version_file)
    content.match(/VERSION\s*=\s*["']([^"']+)["']/)[1]
  end

  def bump_patch_version(version)
    parts = version.split(".")
    parts[2] = (parts[2].to_i + 1).to_s
    parts.join(".")
  end

  def update_version_file(engine, version_file, new_version)
    module_name = engine.split("_").map(&:capitalize).join
    content = <<~RUBY
      module #{module_name}
        VERSION = "#{new_version}"
      end
    RUBY
    File.write(version_file, content)
  end

  def update_release_notes(engine, engine_dir, new_version, commits)
    release_notes_file = File.join(engine_dir, "RELEASE_NOTES.md")
    existing_content = File.exist?(release_notes_file) ? File.read(release_notes_file) : ""

    new_content = <<~MD
      ## v#{new_version} (#{Date.today})

      ### Changes
      #{commits.map { |c| "- #{c}" }.join("\n")}

    MD

    File.write(release_notes_file, new_content + existing_content)
  end

  def commit_changes
    puts
    success "[Step 3] Committing version updates..."

    if @changed_engines.empty?
      warn "No engines have changes to release"
      return
    end

    changed_summary = @changed_engines.map { |e| "#{e}@#{@engine_versions[e]}" }.join(" ")
    system("git add -A")
    system("git commit -m 'chore(release): bump versions - #{changed_summary}'")
    success "Committed version updates"
  end

  def build_gems
    puts
    success "[Step 4] Building gems..."

    FileUtils.rm_rf(@build_dir)
    FileUtils.mkdir_p(@build_dir)

    @changed_engines.each do |engine|
      engine_dir = File.join(@engines_dir, engine)
      info "Building #{engine}..."

      Dir.chdir(engine_dir) do
        system("gem build #{engine}.gemspec")
        gem_file = Dir.glob("*.gem").first
        FileUtils.mv(gem_file, @build_dir) if gem_file
      end

      success "  Built: #{engine}-#{@engine_versions[engine]}.gem"
    end
  end

  def print_summary
    puts
    puts colorize(:blue, "========================================")
    puts colorize(:green, "  Release preparation complete!")
    puts colorize(:blue, "========================================")

    puts
    warn "Built gems:"
    Dir.glob(File.join(@build_dir, "*.gem")).each do |gem|
      puts "  #{File.basename(gem)}"
    end
    puts "  (no gems built)" if @changed_engines.empty?

    puts
    warn "Next steps:"
    puts "  1. Review the changes:"
    puts "     git log --oneline main..#{@release_branch}"
    puts
    puts "  2. Push all gems:"
    puts "     for gem in #{@build_dir}/*.gem; do gem push \"$gem\"; done"
    puts
    puts "  3. Merge release branch to main and push:"
    puts "     git checkout main"
    puts "     git merge #{@release_branch}"
    puts "     git push origin main"
    puts "     git branch -d #{@release_branch}"
    puts
    puts "  4. Create git tags (optional):"
    @changed_engines.each do |engine|
      puts "     git tag #{engine}-v#{@engine_versions[engine]}"
    end
    puts "     git push origin --tags"
  end

  def colorize(color, text)
    "#{COLORS[color]}#{text}#{COLORS[:reset]}"
  end

  def info(msg)
    puts colorize(:blue, msg)
  end

  def success(msg)
    puts colorize(:green, msg)
  end

  def warn(msg)
    puts colorize(:yellow, msg)
  end

  def error(msg)
    puts colorize(:red, "Error: #{msg}")
  end
end

Release.new.run
