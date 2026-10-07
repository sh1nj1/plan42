require_relative "../../../collavre/test/application_system_test_case"

class CommentTranslationLayoutTest < ApplicationSystemTestCase
  test "real comment rows do not grow when translation controls change state" do
    user = users(:two)
    user.update!(password: SystemHelpers::PASSWORD, email_verified_at: Time.current)
    sign_in_via_ui(user)
    visit collavre.user_path(user)
    comment = creatives(:tshirt).comments.create!(user: user, content: "Translation layout test.")
    CollavreTranslation.model = "test-model"

    %i[en ko].each do |locale|
      html = Collavre::Current.set(user: user) do
        I18n.with_locale(locale) do
          Collavre::CommentsController.render(partial: "collavre/comments/comment", locals: { comment: comment })
        end
      end
      [ 320, 240 ].each do |width|
        %w[completed skipped failed].each do |terminal_status|
          page.execute_script(<<~JS, html, width, terminal_status, CollavreTranslation::Translation.digest(comment.content))
            window.layoutFetch ||= window.fetch;
            window.layoutStatus = 'processing';
            window.fetch = (url, options) => String(url).includes('/translation/comments/') ?
              Promise.resolve(new Response(JSON.stringify({status: window.layoutStatus,
                source_digest: arguments[3], content: 'Translation layout test.'}),
                {status: 200, headers: {'Content-Type': 'application/json'}})) : window.layoutFetch(url, options);
            const fixture = document.createElement('div');
            fixture.id = 'translation-layout-fixture';
            fixture.style.cssText = `position:fixed;top:0;left:0;width:${arguments[1]}px;z-index:9999;background:white`;
            fixture.setAttribute('data-controller', 'comment-translation-reader');
            fixture.innerHTML = arguments[0];
            document.body.append(fixture);
          JS
          assert_selector '#translation-layout-fixture .comment-content-action-controls button:disabled'
          height = page.evaluate_script("document.querySelector('#translation-layout-fixture .comment-item').getBoundingClientRect().height")
          height_without_controls = page.evaluate_script(<<~JS)
            (() => {
              const row = document.querySelector('#translation-layout-fixture .comment-item');
              const controls = row.querySelector('.comment-content-action-controls');
              controls.style.display = 'none';
              const height = row.getBoundingClientRect().height;
              controls.style.removeProperty('display');
              return height;
            })()
          JS
          assert_in_delta height_without_controls, height, 0.5, "Controls added empty space"
          page.execute_script("window.layoutStatus = arguments[0]", terminal_status)
          if terminal_status == "completed"
            assert_selector '#translation-layout-fixture .comment-content-action-controls button:not(:disabled)'
            button = find('#translation-layout-fixture .comment-content-action-controls button')
            assert_equal I18n.t('collavre_translation.original', locale: locale), button.text
            assert_equal button.text, button[:title]
            assert_equal button.text, button['aria-label']
            button.click
            assert_equal I18n.t('collavre_translation.show_translation', locale: locale), button[:title]
            assert_equal button[:title], button['aria-label']
          elsif terminal_status == "failed"
            retry_label = I18n.t('collavre_translation.translate', locale: locale)
            assert_selector '#translation-layout-fixture .comment-content-action-controls button:not(:disabled)', text: retry_label
            button = find('#translation-layout-fixture .comment-content-action-controls button')
            assert_equal retry_label, button[:title]
            assert_equal retry_label, button['aria-label']
          else
            assert_no_selector '#translation-layout-fixture .comment-content-action-controls button'
          end
          final_height = page.evaluate_script("document.querySelector('#translation-layout-fixture .comment-item').getBoundingClientRect().height")
          assert_in_delta height, final_height, 0.5, "Row changed for #{locale}/#{width}/#{terminal_status}"
          page.execute_script("document.querySelector('#translation-layout-fixture').remove(); window.fetch = window.layoutFetch")
        end
      end
    end
  ensure
    CollavreTranslation.model = nil
  end
end
