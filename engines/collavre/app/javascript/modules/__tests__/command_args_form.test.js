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


describe('CommandArgsForm keep command', () => {
  const command = baseCommand({
    name: 'keep', label: '/keep', input_schema: [
      { name: 'max', type: 'integer', minimum: 1, maximum: 50, required: false },
      { name: 'agent_name', type: 'string', format: 'keep_agent', required: false },
      { name: 'goal', type: 'string', required: false }
    ]
  })

  test.each(['0', '-1', '51', '1.5'])('rejects invalid iteration limit %s before submission', (value) => {
    const submitted = []
    const form = new CommandArgsForm({ onSubmit: text => submitted.push(text) })
    form.show(command)
    fieldFor('max').value = value
    form._submit()
    expect(submitted).toEqual([])
    expect(form.isOpen()).toBe(true)
    expect(fieldFor('max').classList.contains('modal-dialog-error')).toBe(true)
    expect(document.activeElement).toBe(fieldFor('max'))
    fieldFor('max').value = '10'
    form._submit()
    expect(submitted).toEqual(['/keep --max 10'])
    form.hide()
  })

  test('uses an agent-only search scope only for keep fields', async () => {
    const originalFetch = global.fetch
    const urls = []
    global.fetch = async url => {
      urls.push(new URL(url))
      return { ok: true, json: async () => [] }
    }
    try {
      const form = new CommandArgsForm({ creativeIdFn: () => 123 })
      form.show(command)
      fieldFor('agent_name').value = '@Vrex'
      fieldFor('agent_name').dispatchEvent(new Event('input'))
      await new Promise(resolve => setTimeout(resolve, 250))
      expect(urls[0].searchParams.get('scope')).toBe('keep_agents')
      expect(urls[0].searchParams.get('creative_id')).toBe('123')
      await form._fetchMentions('Vrex', 'mention')
      expect(urls[1].searchParams.has('scope')).toBe(false)
      form.hide()
    } finally {
      global.fetch = originalFetch
    }
  })

  test.each([
    [{}, '/keep'],
    [{ goal: '목표 달성' }, '/keep 목표 달성'],
    [{ max: '5' }, '/keep --max 5'],
    [{ agent_name: '@Agent Name:' }, '/keep @Agent Name:'],
    ...['Vrex', '@Vrex', 'Vrex:', '@Vrex:', '  Vrex  ', '  @Vrex:  '].map(agent_name => [
      { agent_name, goal: 'Fix bugs' }, '/keep @Vrex: Fix bugs'
    ]),
    [{ agent_name: '   ', goal: 'Fix bugs' }, '/keep Fix bugs'],
    [{ max: '8', agent_name: '@Agent Name:', goal: 'Fix bugs\nThen verify' },
      '/keep --max 8 @Agent Name: Fix bugs\nThen verify'],
    ...['@Vrex: investigate', '--max 1 investigate', '-- investigate', '--'].map(goal => [
      { goal }, `/keep -- ${goal}`
    ]),
    [{ max: '5', agent_name: 'Vrex', goal: '@Other: investigate' },
      '/keep --max 5 @Vrex: -- @Other: investigate'],
    [{ max: '1' }, '/keep --max 1'],
    [{ max: '50' }, '/keep --max 50'],
    [{ max: '1e1' }, '/keep --max 10']
  ])('submits parser-compatible text for %j', (values, expected) => {
    let submitted
    const form = new CommandArgsForm({ onSubmit: (text) => { submitted = text } })
    form.show(command)
    expect(form.isOpen()).toBe(true)
    for (const [name, value] of Object.entries(values)) fieldFor(name).value = value
    form._submit()
    expect(submitted).toBe(expected)
    expect(form.isOpen()).toBe(false)
  })
})
