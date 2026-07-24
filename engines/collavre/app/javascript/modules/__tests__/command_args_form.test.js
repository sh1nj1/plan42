/**
 * @jest-environment jsdom
 */
import CommandArgsForm from '../command_args_form'

const baseCommand = (overrides = {}) => ({
  name: 'foo_tool',
  label: '/foo_tool',
  input_schema: [
    { name: 'creative_id', type: 'string', required: false },
    { name: 'topic_id', type: 'string', required: false },
    { name: 'note', type: 'string', required: false }
  ],
  ...overrides
})

const fieldFor = (paramName) =>
  document.querySelector(`[data-param-name="${paramName}"]`)

describe('CommandArgsForm context auto-fill', () => {
  let container

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    document.body.innerHTML = ''
  })

  test('fills creative_id and topic_id from contextValuesFn', () => {
    const form = new CommandArgsForm({
      container,
      contextValuesFn: () => ({ creative_id: '12508', topic_id: '8455' })
    })

    form.show(baseCommand())

    expect(fieldFor('creative_id').value).toBe('12508')
    expect(fieldFor('topic_id').value).toBe('8455')
    expect(fieldFor('note').value).toBe('')
  })

  test('explicit default_value beats context auto-fill', () => {
    const form = new CommandArgsForm({
      container,
      contextValuesFn: () => ({ creative_id: '12508', topic_id: '8455' })
    })

    form.show(baseCommand({
      input_schema: [
        { name: 'creative_id', type: 'string', required: false, default_value: '999' },
        { name: 'topic_id', type: 'string', required: false }
      ]
    }))

    expect(fieldFor('creative_id').value).toBe('999')
    expect(fieldFor('topic_id').value).toBe('8455')
  })

  test('does not fill unrelated params even if names overlap', () => {
    const form = new CommandArgsForm({
      container,
      contextValuesFn: () => ({ creative_id: '12508', topic_id: '8455', note: 'ctx' })
    })

    form.show(baseCommand())

    expect(fieldFor('note').value).toBe('')
  })

  test('missing context values leave fields empty', () => {
    const form = new CommandArgsForm({
      container,
      contextValuesFn: () => ({ creative_id: null, topic_id: '' })
    })

    form.show(baseCommand())

    expect(fieldFor('creative_id').value).toBe('')
    expect(fieldFor('topic_id').value).toBe('')
  })

  test('contextValuesFn throwing does not break form', () => {
    const form = new CommandArgsForm({
      container,
      contextValuesFn: () => { throw new Error('boom') }
    })

    expect(() => form.show(baseCommand())).not.toThrow()
    expect(fieldFor('creative_id').value).toBe('')
  })

  test('no contextValuesFn provided behaves like before', () => {
    const form = new CommandArgsForm({ container })

    form.show(baseCommand())

    expect(fieldFor('creative_id').value).toBe('')
    expect(fieldFor('topic_id').value).toBe('')
  })
})
