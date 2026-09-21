require "test_helper"

module Collavre
  class HtmlTextTest < ActiveSupport::TestCase
    NBSP = " ".freeze

    # --- plain -------------------------------------------------------------

    test "plain strips tags and keeps inner text" do
      assert_equal "Hello world", HtmlText.plain("<p>Hello <strong>world</strong></p>")
    end

    test "plain returns empty string for nil and blank input" do
      assert_equal "", HtmlText.plain(nil)
      assert_equal "", HtmlText.plain("")
      assert_equal "", HtmlText.plain("<p></p>")
    end

    test "plain decodes the nbsp named reference that strip_tags re-encodes" do
      html = "<p>label#{NBSP}shows</p>"

      # Guard the premise: the HTML5 full sanitizer really does emit `&nbsp;`.
      assert_includes ActionController::Base.helpers.strip_tags(html), "&nbsp;"

      result = HtmlText.plain(html)
      refute_includes result, "&nbsp;"
      assert_equal "label#{NBSP}shows", result
    end

    test "plain decodes named references CGI.unescapeHTML cannot" do
      assert_equal "a…b", HtmlText.plain("<p>a&hellip;b</p>")
      assert_equal "a—b", HtmlText.plain("<p>a&mdash;b</p>")
      assert_equal "50 € now", HtmlText.plain("<p>50 &euro; now</p>")
    end

    test "plain decodes the basic xml entities and numeric references" do
      assert_equal %(A & B <x> "q" 'a'), HtmlText.plain("<p>A &amp; B &lt;x&gt; &quot;q&quot; &#39;a&#39;</p>")
      assert_equal "a#{NBSP}b", HtmlText.plain("<p>a&#160;b</p>")
    end

    test "plain decodes exactly once so escaped markup stays escaped" do
      assert_equal "a &lt; b", HtmlText.plain("<p>a &amp;lt; b</p>")
      assert_equal "&nbsp;", HtmlText.plain("<p>&amp;nbsp;</p>")
    end

    test "plain does not reintroduce markup from escaped input" do
      assert_equal "<script>alert(1)</script>", HtmlText.plain("<p>&lt;script&gt;alert(1)&lt;/script&gt;</p>")
    end

    test "plain preserves authored whitespace including nbsp" do
      assert_equal "a\nb  c#{NBSP}d", HtmlText.plain("a\nb  c#{NBSP}d")
    end

    # --- label -------------------------------------------------------------

    test "label collapses newlines and repeated spaces into single spaces" do
      assert_equal "a b c", HtmlText.label("<p>a\n  b</p><p>   c   </p>")
    end

    test "label collapses nbsp into a plain space" do
      assert_equal "label shows", HtmlText.label("<p>label#{NBSP}shows</p>")
      refute_includes HtmlText.label("<p>label#{NBSP}shows</p>"), NBSP
    end

    test "label returns empty string for blank input" do
      assert_equal "", HtmlText.label(nil)
      assert_equal "", HtmlText.label("<p>#{NBSP}</p>")
    end

    # --- truncated_label ---------------------------------------------------

    test "truncated_label caps length with the default omission" do
      assert_equal "abcdefg...", HtmlText.truncated_label("<p>#{'abcdefghij' * 3}</p>", 10)
    end

    test "truncated_label accepts a custom omission" do
      assert_equal "abcdefghi…", HtmlText.truncated_label("<p>#{'abcdefghij' * 3}</p>", 10, omission: "…")
    end

    test "truncated_label counts a decoded nbsp as one character" do
      # `a&nbsp;b` is 8 characters undecoded but 3 once decoded, so a 5-char cap
      # must keep the whole string rather than truncate it.
      assert_equal "a b", HtmlText.truncated_label("<p>a#{NBSP}b</p>", 5)
    end

    test "truncated_label leaves short text untouched" do
      assert_equal "short", HtmlText.truncated_label("<p>short</p>", 24)
    end

    # --- escape_markdown ---------------------------------------------------

    test "escape_markdown backslash-escapes every construct-forming character" do
      assert_equal "a\\\\b", HtmlText.escape_markdown("a\\b")
      assert_equal "a\\`b", HtmlText.escape_markdown("a`b")
      assert_equal "a\\*b", HtmlText.escape_markdown("a*b")
      assert_equal "a\\_b", HtmlText.escape_markdown("a_b")
      assert_equal "a\\[b\\]", HtmlText.escape_markdown("a[b]")
      assert_equal "a\\(b\\)", HtmlText.escape_markdown("a(b)")
      assert_equal "a\\<b\\>", HtmlText.escape_markdown("a<b>")
      assert_equal "a\\~b", HtmlText.escape_markdown("a~b")
    end

    test "escape_markdown escapes a backslash exactly once" do
      # A naive two-pass gsub would turn `\*` into `\\\*` and render a literal
      # backslash next to the asterisk.
      assert_equal "\\\\\\*", HtmlText.escape_markdown("\\*")
    end

    test "escape_markdown leaves ordinary text alone" do
      assert_equal "버그: 채팅 컨텍스트 & 라벨", HtmlText.escape_markdown("버그: 채팅 컨텍스트 & 라벨")
      assert_equal "", HtmlText.escape_markdown(nil)
    end

    # --- markdown_label ----------------------------------------------------

    test "markdown_label neutralises a link-hijacking title" do
      # A creative described as `x](https://evil.example)` is stored verbatim by
      # comrak, so `"[#{label}](#{path})"` would otherwise close the generated
      # link early and point it at an attacker-chosen destination.
      html = "<p>x](<a href=\"https://evil.example\">https://evil.example</a>)</p>"

      assert_equal "x](https://evil.example)", HtmlText.label(html)
      assert_equal "x\\]\\(https://evil.example\\)", HtmlText.markdown_label(html)
    end

    test "markdown_label keeps decoded angle brackets visible instead of letting them be dropped" do
      # The rich editor stores a typed `<x>` as `&lt;x&gt;`; decoding it to a raw
      # `<x>` inside markdown makes marked emit inline HTML that the sanitizer
      # then deletes, silently corrupting the label.
      html = "<p>A &lt;x&gt; tag</p>"

      assert_equal "A <x> tag", HtmlText.label(html)
      assert_equal "A \\<x\\> tag", HtmlText.markdown_label(html)
    end

    test "markdown_label truncates before escaping so the cap counts visible characters" do
      html = "<p>#{'ab' * 20}</p>"

      assert_equal "abababab...", HtmlText.markdown_label(html, 11)
    end

    test "markdown_label never truncates in the middle of an escape sequence" do
      # `*` lands exactly on the 5-character boundary; escaping afterwards keeps
      # its backslash attached instead of leaving a dangling `\`.
      assert_equal "abcd\\*", HtmlText.markdown_label("<p>abcd*efgh</p>", 5, omission: "")
    end

    test "markdown_label collapses nbsp like label does" do
      assert_equal "label shows", HtmlText.markdown_label("<p>label#{NBSP}shows</p>")
    end

    test "markdown_label returns empty string for blank input" do
      assert_equal "", HtmlText.markdown_label(nil)
      assert_equal "", HtmlText.markdown_label("<p>#{NBSP}</p>")
    end
  end
end
