let trixColorPickerInitialized = false;

// Adds text color and background color pickers to Trix toolbar

if (!trixColorPickerInitialized) {
  trixColorPickerInitialized = true;

  document.addEventListener('trix-initialize', function(event) {
    const editor = event.target.editor;
    if (!editor) return;

    // register custom attributes once
    if (!Trix.config.textAttributes.color) {
      Trix.config.textAttributes.color = {
        styleProperty: 'color',
        inheritable: true
      };
    }
    if (!Trix.config.textAttributes.backgroundColor) {
      Trix.config.textAttributes.backgroundColor = {
        styleProperty: 'background-color',
        inheritable: true
      };
    }

    const toolbar = event.target.toolbarElement;
    if (!toolbar) return;
    const group = toolbar.querySelector('.trix-button-group--text-tools');
    if (!group) return;

    // prevent duplicates when multiple editors present
    if (group.querySelector('.trix-color-button')) return;

    // create text color picker elements
    const colorInput = document.createElement('input');
    colorInput.type = 'color';
    colorInput.className = 'trix-toolbar trix-button-icon trix-color-input';
    colorInput.value = '#000000';

    const colorButton = document.createElement('button');
    colorButton.type = 'button';
    colorButton.className = 'trix-toolbar trix-button--icon trix-button trix-color-button';
    colorButton.title = 'Text Color';
    colorButton.innerHTML =
      '<svg viewBox="0 0 20 20" class="trix-icon">\
         <text x="3" y="14" font-size="14" fill="#000">A</text>\
         <line class="underline" x1="2" y1="17" x2="18" y2="17" stroke="#000" stroke-width="2"/>\
       </svg>';
    const underline = colorButton.querySelector('.underline');
    underline.setAttribute('stroke', colorInput.value);

    colorButton.addEventListener('click', function() {
      colorInput.click();
    });
    colorInput.addEventListener('input', function() {
      editor.activateAttribute('color', this.value);
      underline.setAttribute('stroke', this.value);
      updateButtonStates();
    });

    // create background color picker elements
    const bgInput = document.createElement('input');
    bgInput.type = 'color';
    bgInput.className = 'trix-bgcolor-input';
    bgInput.value = '#ffff00';

    const bgButton = document.createElement('button');
    bgButton.type = 'button';
    bgButton.className = 'trix-toolbar trix-button--icon trix-button trix-bgcolor-button';
    bgButton.title = 'Background Color';
    bgButton.innerHTML =
      '<svg viewBox="0 0 20 20" class="trix-icon">\
         <path d="M5 2l8 8-4 4-8-8z" stroke="#000" stroke-width="2" fill="#fff"/>\
         <path class="paint" d="M14 13c0 1.66 1.34 3 3 3s3-1.34 3-3-1-2.5-3-4.5c-2 2-3 2.84-3 4.5z" fill="#ffff00"/>\
       </svg>';
    const paint = bgButton.querySelector('.paint');

    bgButton.addEventListener('click', function() {
      bgInput.click();
    });
    bgInput.addEventListener('input', function() {
      editor.activateAttribute('backgroundColor', this.value);
      paint.setAttribute('fill', this.value);
      updateButtonStates();
    });

    function getAttributes() {
      if (typeof editor.getCurrentAttributes === 'function') {
        return editor.getCurrentAttributes();
      }
      const range = editor.getSelectedRange();
      const doc = editor.getDocument();
      if (doc) {
        if (typeof doc.getCommonAttributes === 'function') {
          return doc.getCommonAttributes(range);
        }
        if (typeof doc.getCommonAttributesForRange === 'function') {
          return doc.getCommonAttributesForRange(range);
        }
        if (typeof doc.getCommonAttributesAtRange === 'function') {
          return doc.getCommonAttributesAtRange(range);
        }
      }
      return {};
    }

    function updateButtonStates() {
      const attrs = getAttributes();
      const color = attrs.color;
      const background = attrs.backgroundColor;
      colorButton.classList.toggle('trix-active', !!color);
      bgButton.classList.toggle('trix-active', !!background);
      if (color) {
        underline.setAttribute('stroke', color);
        colorInput.value = color;
      }
      if (background) {
        paint.setAttribute('fill', background);
        bgInput.value = background;
      }
    }

    event.target.addEventListener('trix-selection-change', updateButtonStates);
    event.target.addEventListener('trix-change', updateButtonStates);

    group.appendChild(colorButton);
    group.appendChild(bgButton);
    group.appendChild(colorInput);
    group.appendChild(bgInput);
    updateButtonStates();
  });
}
