import { escapeHtmlText, escapeHtmlDoubleQuoted, escapeHtmlAttribute } from '../html_escape'
import EntityListController from '../../controllers/entity_list_controller'
import TopicListController from '../../controllers/topic_list_controller'
import TopicSearchController from '../../controllers/topic_search_controller'
import LinkCreativeController from '../../controllers/link_creative_controller'

const value = `&<>"'`

test('text and attribute helpers keep their distinct quote contracts', () => {
    expect(escapeHtmlText(value)).toBe(`&amp;&lt;&gt;"'`)
    expect(escapeHtmlDoubleQuoted(value)).toBe(`&amp;&lt;&gt;&quot;'`)
    expect(escapeHtmlAttribute(value)).toBe('&amp;&lt;&gt;&quot;&#039;')
})

test.each([null, undefined, 0, false, '', value])('preserves entity and creative picker coercion for %p', input => {
    expect(EntityListController.prototype._escape(input)).toBe(escapeHtmlDoubleQuoted(String(input == null ? '' : input)))
    expect(LinkCreativeController.prototype._escape(input)).toBe(escapeHtmlAttribute(String(input || '')))
})

test.each([null, undefined, 0, false, '', value])('preserves topic list and search text coercion for %p', input => {
    const rendered = TopicListController.prototype.renderItem({ label: input })
    expect(rendered).toContain(`>${escapeHtmlText(String(input || ''))}</span>`)
    expect(TopicSearchController.prototype.renderItem({ label: input })).toBe(escapeHtmlText(input || ''))
})

test('topic search retains string-only input contract and create wrapper', () => {
    expect(() => TopicSearchController.prototype.renderItem({ label: 3 })).toThrow(TypeError)
    expect(TopicSearchController.prototype.renderItem({ label: value, isCreate: true })).toBe(`<span class="topic-create-option">${escapeHtmlText(value)}</span>`)
})
