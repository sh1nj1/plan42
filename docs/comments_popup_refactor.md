# Comment Popup Refactor

This application now uses the [Lit](https://lit.dev/) web component framework and the [LiveStore](https://livestore.dev/) state management library for the comment popup.

## Setup
- Dependencies are pinned via the Rails import map. See `config/importmap.rb` for the Lit and LiveStore entries.
- The web component is implemented in `app/javascript/comments_popup_component.js` and registered as `<comments-popup>`.
- Views render the component through `app/views/comments/_comments_popup.html.erb`.

## Usage
The component maintains its comments through a shared LiveStore instance. Other modules can add new comments by calling:

```javascript
import { addComment } from "comments_popup_component";
addComment("Hello world");
```

Lit automatically updates the DOM whenever the store changes.
