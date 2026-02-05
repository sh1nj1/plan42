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
    cyan: "\e[0;36m",
    reset: "\e[0m"
  }.freeze

  def initialize
    @project_root = File.expand_path("..", __dir__)
    @engines_dir = File.join(@project_root, "engines")
    @build_dir = File.join(@project_root, "build", "gems")
    @release_branch = "release/#{Time.now.strftime('%Y%m%d-%H%M%S')}"
    @engines = discover_engines
    @engine_versions = {}
    @engine_commits = {}
    @changed_engines = []
  end

  def run
    Dir.chdir(@project_root)

    print_header
    check_prerequisites

    # Step 1: Analyze changes first (before creating branch)
    collect_changes_and_prompt_versions

    # Exit early if no changes
    if @changed_engines.empty?
      puts
      warn "✨ No engines have changes to release. Nothing to do!"
      exit 0
    end

    # Step 2: Create release branch and update files
    create_release_branch
    update_files_and_gemfile_lock

    # Step 3: Run tests (after version updates)
    run_tests

    # Step 4-6: Commit, build, push, finalize
    commit_changes
    build_and_push_gems
    finalize_release
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
    current_branch = `git branch --show-current`.strip
    unless current_branch == "main"
      error "Must be on main branch (currently on: #{current_branch})"
      exit 1
    end

    unless `git status --porcelain`.strip.empty?
      error "Uncommitted changes exist. Please commit or stash first."
      exit 1
    end

    warn "Pulling latest from main..."
    system("git pull origin main") || exit(1)
  end

  def collect_changes_and_prompt_versions
    puts
    success "[Step 1] Analyzing changes and collecting version input..."

    @engines.each do |engine|
      collect_engine_changes(engine)
    end
  end

  def collect_engine_changes(engine)
    engine_dir = File.join(@engines_dir, engine)
    version_file = File.join(engine_dir, "lib", engine, "version.rb")

    unless File.exist?(version_file)
      warn "#{engine}: version.rb not found, skipping"
      return
    end

    current_version = extract_version(version_file)
    last_version_commit = `git log -1 --format="%H" -- #{version_file} 2>/dev/null`.strip

    commits = if last_version_commit.empty?
      `git log --oneline -- #{engine_dir} 2>/dev/null`.lines.first(20)
    else
      `git log --oneline #{last_version_commit}..HEAD -- #{engine_dir} 2>/dev/null`.lines
    end

    commits = commits.map(&:strip).reject(&:empty?)

    if commits.any?
      @engine_commits[engine] = commits
      default_version = bump_patch_version(current_version)

      puts
      puts colorize(:cyan, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
      puts colorize(:blue, "#{engine}") + " (current: #{current_version})"
      puts colorize(:cyan, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
      puts
      puts colorize(:yellow, "Changes since last release:")
      commits.each { |c| puts "  • #{c}" }
      puts

      print "New version [#{colorize(:green, default_version)}]: "
      input = $stdin.gets.strip
      new_version = input.empty? ? default_version : input

      @engine_versions[engine] = new_version
      @changed_engines << engine

      puts colorize(:green, "→ #{engine} will be released as v#{new_version}")
    else
      puts colorize(:yellow, "#{engine}:") + " No changes since last release (staying at #{current_version})"
    end
  end

  def create_release_branch
    puts
    success "[Step 2] Creating release branch: #{@release_branch}"
    system("git checkout -b #{@release_branch}") || exit(1)
  end

  def update_files_and_gemfile_lock
    puts
    success "[Step 2] Updating version files and Gemfile.lock..."

    @changed_engines.each do |engine|
      engine_dir = File.join(@engines_dir, engine)
      version_file = File.join(engine_dir, "lib", engine, "version.rb")
      new_version = @engine_versions[engine]
      commits = @engine_commits[engine]

      update_version_file(engine, version_file, new_version)
      update_release_notes(engine, engine_dir, new_version, commits)
      info "  Updated #{engine} to v#{new_version}"
    end

    # Update Gemfile.lock
    warn "Updating Gemfile.lock..."
    system("bundle install") || exit(1)
    success "Gemfile.lock updated"
  end

  def run_tests
    puts
    success "[Step 3] Running tests..."

    warn "Running npm test..."
    unless system("npm test")
      rollback_on_failure("npm test failed")
    end

    warn "Running rake test..."
    unless system("bundle exec rake test")
      rollback_on_failure("rake test failed")
    end

    warn "Running rake test:system..."
    unless system("bundle exec rake test:system")
      rollback_on_failure("rake test:system failed")
    end

    success "All tests passed!"
  end

  def rollback_on_failure(reason)
    puts
    error reason
    warn "Rolling back to main branch..."
    system("git checkout main")
    system("git branch -D #{@release_branch} 2>/dev/null")
    error "Release aborted. Please fix the issues and try again."
    exit 1
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
    success "[Step 4] Committing version updates..."

    changed_summary = @changed_engines.map { |e| "#{e}@#{@engine_versions[e]}" }.join(" ")
    system("git add -A")
    system("git commit -m 'chore(release): bump versions - #{changed_summary}'")
    success "Committed version updates"
  end

  def build_and_push_gems
    puts
    success "[Step 5] Building and pushing gems..."

    FileUtils.rm_rf(@build_dir)
    FileUtils.mkdir_p(@build_dir)

    @changed_engines.each do |engine|
      engine_dir = File.join(@engines_dir, engine)
      new_version = @engine_versions[engine]
      gem_filename = "#{engine}-#{new_version}.gem"

      info "Building #{engine}..."
      Dir.chdir(engine_dir) do
        unless system("gem build #{engine}.gemspec")
          error "Failed to build #{engine}"
          exit 1
        end
        gem_file = Dir.glob("*.gem").first
        FileUtils.mv(gem_file, @build_dir) if gem_file
      end

      gem_path = File.join(@build_dir, gem_filename)
      info "Pushing #{gem_filename}..."

      unless system("gem push #{gem_path}")
        error "Failed to push #{gem_filename}"
        puts
        warn "You can retry manually:"
        puts "  gem push #{gem_path}"
        exit 1
      end

      success "  ✓ #{gem_filename} pushed successfully"
    end

    success "All gems pushed!"
  end

  def finalize_release
    puts
    success "[Step 6] Finalizing release..."

    # Merge to main
    warn "Merging #{@release_branch} to main..."
    system("git checkout main") || exit(1)
    system("git merge #{@release_branch} --no-edit") || exit(1)

    # Push to origin
    warn "Pushing to origin..."
    system("git push origin main") || exit(1)

    # Create and push tags
    warn "Creating tags..."
    @changed_engines.each do |engine|
      tag = "#{engine}-v#{@engine_versions[engine]}"
      system("git tag #{tag}")
      info "  Created tag: #{tag}"
    end
    system("git push origin --tags") || exit(1)

    # Cleanup release branch
    system("git branch -d #{@release_branch}")

    print_final_summary
  end

  def print_final_summary
    puts
    puts colorize(:blue, "========================================")
    puts colorize(:green, "  🎉 Release complete!")
    puts colorize(:blue, "========================================")
    puts
    puts colorize(:yellow, "Released gems:")
    @changed_engines.each do |engine|
      puts "  • #{engine}-#{@engine_versions[engine]}"
    end
    puts
    puts colorize(:yellow, "Release notes:")
    @changed_engines.each do |engine|
      puts
      puts colorize(:cyan, "#{engine} v#{@engine_versions[engine]}:")
      @engine_commits[engine].each { |c| puts "  - #{c}" }
    end
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
