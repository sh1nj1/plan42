# frozen_string_literal: true

# `rake clean` (a.k.a. `bin/rails clean`)
#
# One command to reset regenerable local development artifacts. Its main job
# is clobbering public/assets: a stray `assets:precompile` in development
# leaves a public/assets/.manifest.json, and Propshaft switches to its Static
# resolver whenever that file exists — even in development — so newly added
# engine assets (e.g. collavre_plan/timeline.css) raise MissingAssetError
# until the manifest is gone. tmp/ and log/ are cleared too. Every target is
# gitignored, regenerable output, so this is always safe in development.
desc "Reset local dev artifacts: clobber public/assets (Propshaft manifest included), clear tmp and log"
task clean: :environment do
  if Rails.env.production?
    abort "rake clean is development-only; refusing to run in #{Rails.env}"
  end

  %w[assets:clobber tmp:clear log:clear].each { |name| Rake::Task[name].invoke }
  puts "✓ cleaned: public/assets (Propshaft manifest included), tmp, log"
end
