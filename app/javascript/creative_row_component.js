class CreativeRowComponent extends HTMLElement {
  connectedCallback() {
    if (this.rendered) return;
    this.rendered = true;

    const actions = this.querySelector('[slot="actions"]');
    const content = this.querySelector('[slot="content"]');
    const end = this.querySelector('[slot="end"]');

    this.innerHTML = '';

    const row = document.createElement('div');
    row.className = 'creative-row';

    const start = document.createElement('div');
    start.className = 'creative-row-start';

    const actionsContainer = document.createElement('div');
    actionsContainer.className = 'creative-row-actions';
    if (actions) actionsContainer.appendChild(actions);

    start.appendChild(actionsContainer);
    if (content) start.appendChild(content);

    row.appendChild(start);
    if (end) row.appendChild(end);

    this.appendChild(row);
  }
}

customElements.define('creative-row', CreativeRowComponent);
