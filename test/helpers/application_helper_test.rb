require "test_helper"

class ApplicationHelperTest < ActionView::TestCase
  include ApplicationHelper

  test "embed_youtube_iframe keeps attached video with native controls" do
    html = %(<p>intro</p><video controls src="/public-assets/blobs/abc/clip.mp4"></video>)
    result = embed_youtube_iframe(html)

    assert_includes result, "<video"
    assert_match(/controls/, result)
    assert_includes result, "/public-assets/blobs/abc/clip.mp4"
  end

  test "embed_youtube_iframe keeps video with nested source and poster" do
    html = %(<video controls preload="metadata" poster="/p.jpg"><source src="/v.webm" type="video/webm"></video>)
    result = embed_youtube_iframe(html)

    assert_includes result, "<video"
    assert_includes result, "<source"
    assert_includes result, "/v.webm"
    assert_includes result, "poster"
  end

  test "embed_youtube_iframe still converts youtube links to iframes" do
    html = %(<a href="https://www.youtube.com/watch?v=dQw4w9WgXcQ">watch</a>)
    result = embed_youtube_iframe(html)

    assert_includes result, "<iframe"
    assert_includes result, "youtube.com/embed/dQw4w9WgXcQ"
  end

  test "embed_youtube_iframe still strips unsafe markup" do
    html = %(<p>ok</p><script>alert(1)</script>)
    result = embed_youtube_iframe(html)

    assert_not_includes result, "<script"
  end

  # The display sanitizer must preserve the explicit code-fence language on
  # <pre lang>. tree_builder renders the body child-row description through
  # embed_youtube_iframe, while the editor and the current-creative heading use
  # the raw description. If lang is stripped here, the body row loses the
  # language and the client content-detects it — turning a ```javascript block
  # of ruby-ish source into Ruby in the body while the heading and editor stay
  # JavaScript (same code, two colors).
  test "embed_youtube_iframe keeps the code-fence language on <pre lang>" do
    html = %(<pre lang="javascript"><code>def call; end</code></pre>)
    result = embed_youtube_iframe(html)

    assert_includes result, %(lang="javascript")
  end

  test "embed_youtube_iframe returns blank input unchanged" do
    assert_equal "", embed_youtube_iframe("")
    assert_nil embed_youtube_iframe(nil)
  end
end
