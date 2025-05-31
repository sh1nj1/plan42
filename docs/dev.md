
# FAQ

### 개발시 CSS 수정후 즉시 반영 안됨

아래와 같이 해야 반영 되는 문제가 있었음

* `rails assets:precompile`
* `bin/importmap json`
* restart server

해결:

* `rm -rf public/assets`

### open prod console

`kamal app exec -i ./bin/rails console`

### show docker volume path

`docker volume inspect plan42_storage`

### send data to javascript

Pass Translations via Data Attributes (Recommended for External JS Files)

If your JS is in a separate file (like select_mode.js), you can't use ERB directly. Instead, pass the translation from your view to the DOM, then read it in JS.

Example: In your ERB view:

```erb
<button id="select-btn" data-cancel-text="<%= t('app.cancel_select') %>">...</button>
```

In your JS:

```javscript
const selectBtn = document.getElementById('select-btn');
selectBtn.textContent = selectBtn.dataset.cancelText;
```

