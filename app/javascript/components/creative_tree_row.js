import { LitElement, html, nothing } from "lit";
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
    descriptionHtml: { state: true },
    progressHtml: { state: true },
    editIconHtml: { state: true },
    editOffIconHtml: { state: true },
    originLinkHtml: { state: true },
    isTitle: { type: Boolean, attribute: "is-title", reflect: true }
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
    this.descriptionHtml = "";
    this.progressHtml = "";
    this.editIconHtml = "";
    this.editOffIconHtml = "";
    this.originLinkHtml = "";
    this.isTitle = false;
    this._templatesExtracted = false;

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

  updated() {
    this._attachHandlers();
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
      if (hasCached("descriptionHtml")) this.descriptionHtml = this.dataset.descriptionHtml;
      if (hasCached("progressHtml")) this.progressHtml = this.dataset.progressHtml;
      if (hasCached("editIconHtml")) this.editIconHtml = this.dataset.editIconHtml;
      if (hasCached("editOffIconHtml")) this.editOffIconHtml = this.dataset.editOffIconHtml;
      if (hasCached("originLinkHtml")) this.originLinkHtml = this.dataset.originLinkHtml;

      // If we lack cached markup (older snapshots), attempt to extract from the existing DOM.
      if (!hasCached("descriptionHtml") && existingTree) {
        const content = existingTree.querySelector(".creative-content");
        ensureCached("descriptionHtml", content ? content.innerHTML : "");
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
            this.descriptionHtml = markup;
            this.dataset.descriptionHtml = markup;
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
        <div class="creative-row" data-creatives--select-mode-target="row">
          <div class="creative-row-start">
            <div class="creative-row-actions">
              ${this._renderCheckbox()}
              ${this._renderActionButton()}
            </div>
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
          <h1 class="page-title" style="display:flex;align-items:center;gap:1em;">
            <div class="creative-title-content">
              ${unsafeHTML(this.descriptionHtml || "")}
            </div>
            ${this.originLinkHtml ? unsafeHTML(this.originLinkHtml) : nothing}
          </h1>
          <div>
            <h1 style="display:flex;align-items:center;gap:1em;">
              ${unsafeHTML(this.progressHtml || "")}
            </h1>
          </div>
        </div>
      </div>
    `;
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
    const toggle = this._renderToggle();
    const content = html`
      <div class="creative-content">
        <a class="unstyled-link" href=${this.linkUrl || "#"}>${unsafeHTML(this.descriptionHtml || "")}</a>
      </div>
    `;

    if (level <= BULLET_STARTING_LEVEL) {
      const headingClass = `indent${level}`;
      if (this.hasChildren || this.isRoot) {
        const headingLevel = Math.max(1, Math.min(level, 6));
        switch (headingLevel) {
          case 1:
            return html`<h1 class=${headingClass}>${toggle}${content}</h1>`;
          case 2:
            return html`<h2 class=${headingClass}>${toggle}${content}</h2>`;
          case 3:
            return html`<h3 class=${headingClass}>${toggle}${content}</h3>`;
          case 4:
            return html`<h4 class=${headingClass}>${toggle}${content}</h4>`;
          case 5:
            return html`<h5 class=${headingClass}>${toggle}${content}</h5>`;
          default:
            return html`<h6 class=${headingClass}>${toggle}${content}</h6>`;
        }
      }
      return html`<div class=${headingClass}>${toggle}${content}</div>`;
    }

    const margin = level > BULLET_STARTING_LEVEL
      ? `margin-left: ${(level - BULLET_STARTING_LEVEL) * 20}px;`
      : "";
    const needsBullet = !((this.descriptionHtml || "").includes("<li>"));
    const bullet = needsBullet ? html`<div class="creative-tree-bullet"></div>` : nothing;
    return html`
      <div class="creative-tree-li" style=${margin}>
        ${toggle}${bullet}${content}
      </div>
    `;
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
}

if (!customElements.get("creative-tree-row")) {
  customElements.define("creative-tree-row", CreativeTreeRow);
}
