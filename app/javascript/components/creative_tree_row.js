import { LitElement, html, nothing } from "lit";
import DOMPurify from "dompurify";
import { unsafeHTML } from "lit/directives/unsafe-html.js";

const BULLET_STARTING_LEVEL = 3;

class CreativeTreeRow extends LitElement {
  static properties = {
    creativeId: { attribute: "creative-id" },
    parentId: { attribute: "parent-id" },
    domId: { attribute: "dom-id" },
    selectMode: { type: Boolean, attribute: "select-mode", reflect: true },
    canWrite: { type: Boolean, attribute: "can-write" },
    level: { type: Number, attribute: "level" },
    hasChildren: { type: Boolean, attribute: "has-children" },
    expanded: { type: Boolean, attribute: "expanded" },
    isRoot: { type: Boolean, attribute: "is-root" },
    linkUrl: { attribute: "link-url" },
    descriptionHtml: { state: true, noAccessor: true },
    progressHtml: { state: true },
    editIconHtml: { state: true },
    editOffIconHtml: { state: true },
    originLinkHtml: { state: true },
    isTitle: { type: Boolean, attribute: "is-title", reflect: true },
    loadingChildren: { type: Boolean, attribute: "loading-children", reflect: true },
    _loadingDotsState: { state: true }
  };

  constructor() {
    super();
    this.creativeId = null;
    this.parentId = null;
    this.domId = null;
    this.selectMode = false;
    this.canWrite = false;
    this.level = 1;
    this.hasChildren = false;
    this.expanded = false;
    this.isRoot = false;
    this.linkUrl = "#";
    this._descriptionHtml = "";
    this.progressHtml = "";
    this.editIconHtml = "";
    this.editOffIconHtml = "";
    this.originLinkHtml = "";
    this.isTitle = false;
    this._templatesExtracted = false;
    this.loadingChildren = false;
    this._loadingDotsState = ['.', '.', '.'];
    this._animationInterval = null;

    this._toggleBtn = null;
    this._editBtn = null;
    this._commentsBtn = null;

    this._handleToggleClick = this._handleToggleClick.bind(this);
    this._handleEditClick = this._handleEditClick.bind(this);
    this._handleCommentsClick = this._handleCommentsClick.bind(this);
  }

  createRenderRoot() {
    return this; // keep light DOM for existing selectors & listeners
  }

  connectedCallback() {
    super.connectedCallback();
    this._extractTemplates();
  }

  updated(changedProperties) {
    this._attachHandlers();

    if (changedProperties.has('loadingChildren')) {
      if (this.loadingChildren) {
        this._startAnimation();
      } else {
        this._stopAnimation();
      }
    }
  }

  disconnectedCallback() {
    super.disconnectedCallback();
    this._stopAnimation();
  }

  get descriptionHtml() {
    return this._descriptionHtml;
  }

  set descriptionHtml(value) {
    const oldValue = this._descriptionHtml;
    // Always sanitize when setting new HTML
    const sanitized = DOMPurify.sanitize(value ?? "");
    this._descriptionHtml = sanitized;
    this.dataset.descriptionHtml = sanitized;
    this.requestUpdate("descriptionHtml", oldValue);
  }

  _setDescriptionHtml(markup) {
    this.descriptionHtml = markup;
  }

  _extractTemplates() {
    if (this._templatesExtracted) return;
    const templates = this.querySelectorAll("template[data-part]");
    const existingTree = this.querySelector(":scope > .creative-tree");
    const hasCached = (key) => Object.prototype.hasOwnProperty.call(this.dataset, key);
    const ensureCached = (key, value) => {
      if (value === undefined || value === null) return;
      this.dataset[key] = value;
      this[key] = value;
    };

    if (templates.length === 0) {
      // The element might have been restored from a Turbo snapshot where we no longer
      // have template nodes, so fall back to any cached markup stored in data attributes.
      if (hasCached("descriptionHtml")) this._setDescriptionHtml(this.dataset.descriptionHtml);
      if (hasCached("progressHtml")) this.progressHtml = this.dataset.progressHtml;
      if (hasCached("editIconHtml")) this.editIconHtml = this.dataset.editIconHtml;
      if (hasCached("editOffIconHtml")) this.editOffIconHtml = this.dataset.editOffIconHtml;
      if (hasCached("originLinkHtml")) this.originLinkHtml = this.dataset.originLinkHtml;

      // If we lack cached markup (older snapshots), attempt to extract from the existing DOM.
      if (!hasCached("descriptionHtml") && existingTree) {
        const content = existingTree.querySelector(".creative-content");
        this._setDescriptionHtml(content ? content.innerHTML : "");
      }
      if (!hasCached("progressHtml") && existingTree) {
        const progressNode = existingTree.querySelector(".creative-row > :last-child");
        ensureCached("progressHtml", progressNode ? progressNode.innerHTML : "");
      }
    } else {
      templates.forEach((template) => {
        const part = template.dataset.part;
        const markup = template.innerHTML;
        switch (part) {
          case "description":
            this._setDescriptionHtml(markup);
            break;
          case "progress":
            this.progressHtml = markup;
            this.dataset.progressHtml = markup;
            break;
          case "edit-icon":
            this.editIconHtml = markup;
            this.dataset.editIconHtml = markup;
            break;
          case "edit-off-icon":
            this.editOffIconHtml = markup;
            this.dataset.editOffIconHtml = markup;
            break;
          case "origin-link":
            this.originLinkHtml = markup;
            this.dataset.originLinkHtml = markup;
            break;
          default:
            break;
        }
        template.remove();
      });
    }

    if (existingTree) existingTree.remove();
    this._templatesExtracted = true;
  }

  _attachHandlers() {
    this._toggleBtn?.removeEventListener("click", this._handleToggleClick);
    this._editBtn?.removeEventListener("click", this._handleEditClick);
    this._commentsBtn?.removeEventListener("click", this._handleCommentsClick);

    this._toggleBtn = this.querySelector(".creative-toggle-btn");
    this._editBtn = this.querySelector(".edit-inline-btn");
    this._commentsBtn = this.querySelector(".comments-btn");

    if (this._toggleBtn) this._toggleBtn.addEventListener("click", this._handleToggleClick, { passive: false });
    if (this._editBtn) this._editBtn.addEventListener("click", this._handleEditClick, { passive: false });
    if (this._commentsBtn) this._commentsBtn.addEventListener("click", this._handleCommentsClick, { passive: false });
  }

  render() {
    if (this.isTitle) {
      return this._renderTitle();
    }

    const dragEnabled = !this.selectMode || this.canWrite;
    const draggableAttr = dragEnabled ? "true" : nothing;
    const dragActions = dragEnabled
      ? "dragstart->creatives--drag-drop#start dragover->creatives--drag-drop#over drop->creatives--drag-drop#drop dragleave->creatives--drag-drop#leave"
      : nothing;

    return html`
      <div
        class="creative-tree"
        id=${this.domId ?? nothing}
        data-id=${this.creativeId ?? nothing}
        data-parent-id=${this.parentId ?? nothing}
        data-level=${this.level ?? nothing}
        draggable=${draggableAttr}
        data-action=${dragActions}
      >
        <div class="creative-row level-${this.level}" data-creatives--select-mode-target="row">
          <div class="creative-row-start">
            ${this._renderCheckbox()}
            ${this._renderActionButton()}
            ${this._renderTreeLines()}
            ${this._renderToggle()}
            ${this._renderContent()}
          </div>
            ${unsafeHTML(this.progressHtml || "")}
        </div>
      </div>
    `;
  }

  _renderTitle() {
    return html`
      <div
        class="creative-tree creative-tree-title"
        id=${this.domId ?? nothing}
        data-id=${this.creativeId ?? nothing}
        data-parent-id=${this.parentId ?? nothing}
      >
        <div class="creative-row" style="background-color: transparent;" data-creatives--select-mode-target="row">
          <div class="creative-row-start" style="align-items: center;">
            ${this._renderActionButton()}
            <div class="creative-toggle-btn" style="visibility: hidden; margin-top: 0;"></div>
            <h1 class="page-title" style="margin-left: 0; margin-bottom: 0; display:flex; align-items:center; gap:1em;">
              <div class="creative-title-content">
                ${unsafeHTML(this.descriptionHtml || "")}
              </div>
              ${this.originLinkHtml ? unsafeHTML(this.originLinkHtml) : nothing}
            </h1>
          </div>
          <div class="creative-row-end">
             <h1 class="page-title" style="margin: 0; display:flex; align-items:center;">
               ${unsafeHTML(this.progressHtml || "")}
             </h1>
          </div>
        </div>
      </div>
    `;
  }

  _renderTreeLines() {
    const level = Number(this.level) || 1;
    const lines = [];
    // Render a tree line for each level of depth minus 1 (since level 1 is root-ish)
    for (let i = 1; i < level; i++) {
      lines.push(html`<div class="tree-line"></div>`);
    }
    return lines;
  }

  _renderCheckbox() {
    const style = this.selectMode ? "" : "display: none";
    return html`
      <input
        type="checkbox"
        name="selected_creative_ids[]"
        class="select-creative-checkbox"
        value=${this.creativeId ?? ""}
        style=${style}
        data-creatives--select-mode-target="checkbox"
        data-action="change->creatives--select-mode#checkboxChanged"
      />
    `;
  }

  _renderActionButton() {
    if (this.canWrite) {
      return html`
        <button type="button" class="creative-action-btn edit-inline-btn" data-creative-id=${this.creativeId}>
          ${unsafeHTML(this.editIconHtml || "")}
        </button>
      `;
    }
    return html`
      <button
        type="button"
        class="creative-action-btn edit-inline-btn"
        data-creative-id=${this.creativeId}
        style="visibility: hidden"
      >
        ${unsafeHTML(this.editOffIconHtml || "")}
      </button>
    `;
  }

  _renderContent() {
    const level = Number(this.level) || 1;
    // Toggle is now rendered outside
    const content = html`
      <div class="creative-content" @click=${this._handleContentClick}>
        ${unsafeHTML(this.descriptionHtml || "")}
      </div>
    `;
    const indicator = this.loadingChildren ? this._renderLoadingIndicator() : nothing;

    if (level <= BULLET_STARTING_LEVEL) {
      const headingClass = `indent${level}`;

      // If no children, render as div instead of heading to avoid large font size
      if (!this.hasChildren) {
        return html`<div class=${headingClass}>${content}${indicator}</div>`;
      }

      // We wrap content in heading tags for semantics
      const headingLevel = Math.max(1, Math.min(level, 6));
      switch (headingLevel) {
        case 1:
          return html`<h1 class=${headingClass}>${content}${indicator}</h1>`;
        case 2:
          return html`<h2 class=${headingClass}>${content}${indicator}</h2>`;
        case 3:
          return html`<h3 class=${headingClass}>${content}${indicator}</h3>`;
        case 4:
          return html`<h4 class=${headingClass}>${content}${indicator}</h4>`;
        case 5:
          return html`<h5 class=${headingClass}>${content}${indicator}</h5>`;
        default:
          return html`<h6 class=${headingClass}>${content}${indicator}</h6>`;
      }
    }

    // For deeper levels, we use div. But we don't need margin-left anymore because we have tree lines.
    // We still keep the bullet if needed.
    const needsBullet = !((this.descriptionHtml || "").includes("<li>"));
    const bullet = needsBullet ? html`<div class="creative-tree-bullet"></div>` : nothing;
    return html`
      <div class="creative-tree-li">
        ${bullet}${content}${indicator}
      </div>
    `;
  }

  _renderLoadingIndicator() {
    return html`
      <span
        class="creative-loading-indicator"
        role="status"
        aria-live="polite"
        aria-label="Loading children"
      >
        <span class="creative-loading-dot" aria-hidden="true">${this._loadingDotsState[0]}</span>
        <span class="creative-loading-dot" aria-hidden="true">${this._loadingDotsState[1]}</span>
        <span class="creative-loading-dot" aria-hidden="true">${this._loadingDotsState[2]}</span>
      </span>
    `;
  }

  _startAnimation() {
    if (this._animationInterval) return;

    const style = getComputedStyle(document.body);
    let emojiString = style.getPropertyValue('--creative-loading-emojis').replace(/"/g, '').trim();

    if (!emojiString) {
      const rootStyle = getComputedStyle(document.documentElement);
      emojiString = rootStyle.getPropertyValue('--creative-loading-emojis').replace(/"/g, '').trim();
    }

    const emojis = emojiString ? emojiString.split(',').map(e => e.trim()) : ['🎨', '💡', '🚀', '✨', '🧩', '🎲'];

    let emojiIndex = 0;
    let frame = 0;

    const updateDots = () => {
      const currentEmoji = emojis[emojiIndex];
      let newState = ['.', '.', '.'];

      switch (frame) {
        case 0:
          newState = ['.', '.', '.'];
          break;
        case 1:
          newState = ['.', '.', currentEmoji];
          break;
        case 2:
          newState = ['.', currentEmoji, '.'];
          break;
        case 3:
          newState = [currentEmoji, '.', '.'];
          break;
      }

      this._loadingDotsState = newState;

      frame++;
      if (frame > 3) {
        frame = 0;
        emojiIndex = (emojiIndex + 1) % emojis.length;
      }
    };

    this._animationInterval = setInterval(updateDots, 80);
    updateDots(); // Initial call
  }

  _stopAnimation() {
    if (this._animationInterval) {
      clearInterval(this._animationInterval);
      this._animationInterval = null;
    }
    this._loadingDotsState = ['.', '.', '.'];
  }

  _renderToggle() {
    const classes = "before-link creative-toggle-btn creative-action-btn";
    if (this.hasChildren) {
      return html`
        <div class=${classes} data-creative-id=${this.creativeId}>${this._toggleSymbol()}</div>
      `;
    }
    return html`
      <div
        class=${classes}
        data-creative-id=${this.creativeId}
        style="visibility: hidden;"
      ></div>
    `;
  }

  _toggleSymbol() {
    return this.expanded ? "▼" : "▶";
  }

  _handleToggleClick(event) {
    if (!this.hasChildren) {
      event.preventDefault();
      event.stopPropagation();
      return;
    }
    event.preventDefault();
    event.stopPropagation();
    this.dispatchEvent(new CustomEvent("creative-toggle-click", {
      detail: {
        creativeId: this.creativeId ?? this.getAttribute("creative-id"),
        component: this,
        button: event.currentTarget,
        treeElement: this.querySelector(".creative-tree")
      },
      bubbles: true,
      composed: true
    }));
  }

  _handleEditClick(event) {
    event.preventDefault();
    event.stopPropagation();
    this.dispatchEvent(new CustomEvent("creative-edit-click", {
      detail: {
        creativeId: this.creativeId ?? this.getAttribute("creative-id"),
        component: this,
        button: event.currentTarget,
        treeElement: this.querySelector(".creative-tree")
      },
      bubbles: true,
      composed: true
    }));
  }

  _handleCommentsClick(event) {
    event.preventDefault();
    event.stopPropagation();
    this.dispatchEvent(new CustomEvent("creative-comments-click", {
      detail: {
        creativeId: this.creativeId ?? this.getAttribute("creative-id"),
        component: this,
        button: event.currentTarget,
        treeElement: this.querySelector(".creative-tree")
      },
      bubbles: true,
      composed: true
    }));
  }

  _handleContentClick(event) {
    // Check if the clicked element is an interactive element or inside one
    const target = event.target;
    if (target.tagName === 'A' || target.closest('a') ||
      target.tagName === 'BUTTON' || target.closest('button') ||
      target.tagName === 'INPUT' || target.closest('input') ||
      target.tagName === 'IMG') {
      // Allow default behavior for these elements (e.g. download link, image click)
      return;
    }

    // If not interactive, navigate to the linkUrl
    if (this.linkUrl && this.linkUrl !== "#") {
      if (window.Turbo) {
        window.Turbo.visit(this.linkUrl);
      } else {
        window.location.href = this.linkUrl;
      }
    }
  }
}

if (!customElements.get("creative-tree-row")) {
  customElements.define("creative-tree-row", CreativeTreeRow);
}
