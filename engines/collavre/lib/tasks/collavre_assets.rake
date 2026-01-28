# frozen_string_literal: true

namespace :collavre do
  desc "Print Collavre gem path for build scripts"
  task :gem_path do
    puts Collavre::Engine.root
  end

  desc "Build JavaScript assets including Collavre engine"
  task :build_js do
    gem_path = Collavre::Engine.root
    ENV["COLLAVRE_GEM_PATH"] = gem_path.to_s
    system("npm run build") || exit(1)
  end
end
