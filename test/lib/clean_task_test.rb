# frozen_string_literal: true

require "test_helper"
require "rake"

# `rake clean` is a development convenience that resets regenerable local
# artifacts (most importantly clobbering public/assets so a stale Propshaft
# .manifest.json can't force the Static resolver into MissingAssetError).
# It must refuse to run outside development/test (production AND desktop, which
# inherits production.rb), where public/assets is the real precompiled output.
class CleanTaskTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("clean")
    Rake::Task["clean"].reenable
  end

  test "clean task is defined" do
    assert Rake::Task.task_defined?("clean")
  end

  # desktop inherits production.rb and ships real precompiled assets, so the
  # guard whitelists dev/test rather than only blocking production.
  test "refuses to run outside development/test (production, desktop)" do
    %w[production desktop].each do |env|
      Rake::Task["clean"].reenable
      Rails.stub(:env, ActiveSupport::StringInquirer.new(env)) do
        assert_raises(SystemExit, "expected clean to abort in #{env}") { Rake::Task["clean"].invoke }
      end
    end
  end

  test "in development invokes assets:clobber, tmp:clear and log:clear in order" do
    invoked = []
    clobber = Rake::Task["assets:clobber"]
    tmp = Rake::Task["tmp:clear"]
    log = Rake::Task["log:clear"]

    clobber.stub(:invoke, ->(*) { invoked << "assets:clobber" }) do
      tmp.stub(:invoke, ->(*) { invoked << "tmp:clear" }) do
        log.stub(:invoke, ->(*) { invoked << "log:clear" }) do
          Rails.stub(:env, ActiveSupport::StringInquirer.new("development")) do
            Rake::Task["clean"].invoke
          end
        end
      end
    end

    assert_equal %w[assets:clobber tmp:clear log:clear], invoked
  end
end
