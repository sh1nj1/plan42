/**
 * @jest-environment jsdom
 */
import { jest } from '@jest/globals';
import { createListenerRegistry } from '../dom_listener_registry';
import { createDelegatedClickHandler } from '../creative_row_editor_delegated_clicks';

function session(template = document.getElementById('inline-edit-form')) {
  return {
    template,
    startNew: jest.fn(),
    hideCurrent: jest.fn(),
    handleEditButtonClick: jest.fn(),
    hideRootEmptyState: jest.fn(() => false),
  };
}

describe('createDelegatedClickHandler', () => {
  beforeEach(() => {
    document.body.innerHTML = `
      <div id="creatives">
        <div class="creative-tree" id="creative-10" data-id="10">
          <button class="add-creative-btn"><span id="nested-add-target">Add</span></button>
          <button class="edit-inline-btn">Edit</button>
          <div class="creative-children" id="creative-children-10">
            <div class="creative-tree" id="creative-11" data-id="11"></div>
          </div>
        </div>
      </div>
      <button class="add-creative-btn" data-parent-id="">Add root</button>
      <button class="new-root-creative-btn">New root</button>
      <button class="append-parent-btn" data-child-id="11">Append parent</button>
      <button class="add-creative-btn" id="inline-add">Inline add</button>
      <div id="inline-edit-form" style="display: none"></div>
    `;
  });

  test('starts one child form with the current Turbo session after rebinding', () => {
    const registry = createListenerRegistry();
    const oldTemplate = document.createElement('div');
    oldTemplate.style.display = 'block';
    const oldSession = session(oldTemplate);
    registry.add(document.body, 'click', createDelegatedClickHandler(oldSession));

    registry.releaseAll();
    const currentSession = session();
    registry.add(document.body, 'click', createDelegatedClickHandler(currentSession));
    document.getElementById('nested-add-target').click();

    expect(oldSession.hideCurrent).not.toHaveBeenCalled();
    expect(oldSession.startNew).not.toHaveBeenCalled();
    expect(currentSession.startNew).toHaveBeenCalledTimes(1);
    expect(currentSession.startNew).toHaveBeenCalledWith(
      '10',
      document.getElementById('creative-children-10'),
      document.getElementById('creative-11'),
      '11'
    );
    registry.releaseAll();
  });

  test('creates a children container when a tree has none', () => {
    document.getElementById('creative-children-10').remove();
    const currentSession = session();
    document.body.addEventListener('click', createDelegatedClickHandler(currentSession), { once: true });

    document.querySelector('#creative-10 .add-creative-btn').click();

    const container = document.getElementById('creative-children-10');
    expect(container).not.toBeNull();
    expect(currentSession.startNew).toHaveBeenCalledWith('10', container, null, '');
  });

  test('uses the root container for an add button outside a tree', () => {
    const currentSession = session();
    const handler = createDelegatedClickHandler(currentSession);
    const button = document.querySelector('body > .add-creative-btn');

    button.addEventListener('click', handler, { once: true });
    button.click();

    expect(currentSession.startNew).toHaveBeenCalledTimes(1);
    expect(currentSession.startNew).toHaveBeenCalledWith(
      '',
      document.getElementById('creatives'),
      document.getElementById('creative-10'),
      '10'
    );
  });

  test('opens a new root creative before the first root', () => {
    const currentSession = session();
    document.body.addEventListener('click', createDelegatedClickHandler(currentSession), { once: true });

    document.querySelector('.new-root-creative-btn').click();

    expect(currentSession.startNew).toHaveBeenCalledWith(
      '',
      document.getElementById('creatives'),
      document.getElementById('creative-10'),
      '10'
    );
  });

  test('inserts at the end when the root empty state is hidden by the session', () => {
    const currentSession = session();
    currentSession.hideRootEmptyState.mockReturnValue(true);
    document.body.addEventListener('click', createDelegatedClickHandler(currentSession), { once: true });

    document.querySelector('.new-root-creative-btn').click();

    expect(currentSession.hideRootEmptyState).toHaveBeenCalledWith(document.getElementById('creatives'));
    expect(currentSession.startNew).toHaveBeenCalledWith('', document.getElementById('creatives'), null, '');
  });

  test('uses the root container for an add button outside a tree when the empty state is hidden', () => {
    const currentSession = session();
    currentSession.hideRootEmptyState.mockReturnValue(true);
    const handler = createDelegatedClickHandler(currentSession);
    const button = document.querySelector('body > .add-creative-btn');

    button.addEventListener('click', handler, { once: true });
    button.click();

    expect(currentSession.hideRootEmptyState).toHaveBeenCalledWith(document.getElementById('creatives'));
    expect(currentSession.startNew).toHaveBeenCalledWith('', document.getElementById('creatives'), null, '');
  });

  test('closes the current form instead of opening another one', () => {
    const currentSession = session();
    currentSession.template.style.display = 'block';
    document.body.addEventListener('click', createDelegatedClickHandler(currentSession), { once: true });

    document.getElementById('nested-add-target').click();

    expect(currentSession.hideCurrent).toHaveBeenCalledTimes(1);
    expect(currentSession.startNew).not.toHaveBeenCalled();
  });

  test('routes edit buttons to the current session', () => {
    const currentSession = session();
    document.body.addEventListener('click', createDelegatedClickHandler(currentSession), { once: true });

    document.querySelector('.edit-inline-btn').click();

    expect(currentSession.handleEditButtonClick).toHaveBeenCalledWith(document.getElementById('creative-10'));
  });

  test('opens a parent form immediately before the selected child', () => {
    const currentSession = session();
    document.body.addEventListener('click', createDelegatedClickHandler(currentSession), { once: true });

    document.querySelector('.append-parent-btn').click();

    expect(currentSession.startNew).toHaveBeenCalledWith(
      '10',
      document.getElementById('creative-children-10'),
      document.getElementById('creative-11'),
      '11',
      '',
      '11'
    );
  });

  test('does not treat inline toolbar controls as delegated add buttons', () => {
    const currentSession = session();
    document.body.addEventListener('click', createDelegatedClickHandler(currentSession), { once: true });

    document.getElementById('inline-add').click();

    expect(currentSession.startNew).not.toHaveBeenCalled();
  });

  test('does nothing when the root container is absent', () => {
    document.getElementById('creatives').remove();
    const currentSession = session();
    const button = document.querySelector('body > .add-creative-btn');
    button.addEventListener('click', createDelegatedClickHandler(currentSession), { once: true });

    expect(() => button.click()).not.toThrow();
    expect(currentSession.startNew).not.toHaveBeenCalled();
  });
});
