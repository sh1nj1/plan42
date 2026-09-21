require "test_helper"

class ApplicationHelperTest < ActionView::TestCase
  include ApplicationHelper

  test "embed_youtube_iframe preserves default-safe formatting" do
    html = "<del>removed</del><ins>added</ins><sub>low</sub><sup>high</sup><dl><dt>term</dt><dd>definition</dd></dl>"

    assert_equal sanitize(html), embed_youtube_iframe(html)
  end

  test "preserves default-safe attributes and rejects unsafe attributes" do
    html = '<p lang="ko"><del datetime="2026-09-22" cite="https://example.com" onclick="alert(1)">Item</del></p>'
    assert_equal sanitize(html), embed_youtube_iframe(html)
    assert_includes embed_youtube_iframe(html), 'lang="ko"'
    assert_includes embed_youtube_iframe(html), 'datetime="2026-09-22"'
    assert_not_includes embed_youtube_iframe(html), "onclick"
  end

  test "preserves PPT metadata while stripping unsafe and unrelated attributes" do
    html = '<div class="ppt-slide" data-ppt-slide="2" data-ppt-width="12192000" data-ppt-height="6858000" data-ppt-format="{&quot;fill&quot;:&quot;#222222&quot;}" data-other="no" onclick="alert(1)">Slide</div>'
    slide = Nokogiri::HTML.fragment(embed_youtube_iframe(html)).at_css(".ppt-slide")
    assert_equal "2", slide["data-ppt-slide"]
    assert_equal "12192000", slide["data-ppt-width"]
    assert_equal "6858000", slide["data-ppt-height"]
    assert_equal({ "fill" => "#222222" }, JSON.parse(slide["data-ppt-format"]))
    assert_nil slide["onclick"]
    assert_nil slide["data-other"]
  end

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

  test "embed_youtube_iframe returns blank input unchanged" do
    assert_equal "", embed_youtube_iframe("")
    assert_nil embed_youtube_iframe(nil)
  end
end
