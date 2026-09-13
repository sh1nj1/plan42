require "test_helper"

# The cron badge renders inside two different hosts — the creative list row and
# the topic chip — whose text color comes from different tokens, and the topic
# chip swaps its color again when selected. Guard the stylesheet against
# re-pinning a single color (which goes invisible on the selected chip) and
# against referencing tokens design_tokens.css never defines (which silently
# collapses to currentColor / the light fallback in dark mode).
class CronBadgeCssTest < ActiveSupport::TestCase
  STYLESHEET_DIR = Collavre::Engine.root.join("app/assets/stylesheets/collavre")
  CRON_SELECTORS = %w[
    .creative-cron-badge
    .popup-menu.cron-badge-popup
    .cron-badge-popup-title
    .cron-task
    .cron-task-label
    .cron-task-message-input
  ].freeze

  setup do
    @css = STYLESHEET_DIR.join("creatives.css").read
    @defined_tokens = STYLESHEET_DIR.join("design_tokens.css").read.scan(/^\s*(--[a-z0-9-]+):/).flatten.to_set
  end

  test "badge count inherits its host's text color instead of pinning one token" do
    declarations = rule_body(".creative-cron-badge")

    assert_match(/color:\s*inherit\s*;/, declarations,
                 "cron badge must inherit the topic chip / creative row text color")
    refute_match(/color:\s*var\(--text-muted\)/, declarations,
                 "a pinned muted grey drops to ~1.1:1 contrast on the selected topic chip")
  end

  test "every design token the cron badge references is defined" do
    CRON_SELECTORS.each do |selector|
      rule_body(selector).scan(/var\((--[a-z0-9-]+)/) do |(token)|
        assert_includes @defined_tokens, token,
                        "#{selector} references #{token}, which design_tokens.css does not define " \
                        "(it would fall back to the light value in dark mode)"
      end
    end
  end

  private

  def rule_body(selector)
    match = @css.match(/^#{Regexp.escape(selector)}\s*\{(.*?)\}/m)
    assert match, "#{selector} rule not found in creatives.css"
    match[1]
  end
end
