import { LitElement, html, css } from "lit";
import LiveStore from "livestore";

// Create a simple store for comments using LiveStore
const commentStore = new LiveStore({ comments: [] });

// Helper to add comments to the store from other scripts
export function addComment(content) {
  const current = commentStore.get().comments;
  commentStore.set({ comments: [...current, content] });
}

export class CommentsPopup extends LitElement {
  static properties = {
    loadingText: { type: String, attribute: 'data-loading-text' },
    deleteConfirmText: { type: String, attribute: 'data-delete-confirm-text' },
    updateCommentText: { type: String, attribute: 'data-update-comment-text' },
    commentsTitleText: { type: String, attribute: 'data-comments-title-text' },
    comments: { state: true }
  };

  constructor() {
    super();
    this.comments = [];
    this.unsubscribe = commentStore.subscribe(state => {
      this.comments = state.comments;
    });
  }

  disconnectedCallback() {
    this.unsubscribe();
    super.disconnectedCallback();
  }

  render() {
    return html`
      <div id="comments-popup" class="popup-box">
        <button id="close-comments-btn" class="popup-close-btn">&times;</button>
        <h3 style="margin-top:0;">${this.commentsTitleText || ''}</h3>
        <div id="comment-participants"></div>
        <div id="comments-list">
          ${this.comments.length === 0
            ? this.loadingText
            : this.comments.map(c => html`<div class="comment-item">${c}</div>`)}
        </div>
        <form id="new-comment-form">
          <textarea name="comment[content]" rows="2" required></textarea>
          <button class="creative-action-btn" type="submit">
            <slot name="send-icon"></slot>
          </button>
        </form>
      </div>`;
  }
}

customElements.define('comments-popup', CommentsPopup);
