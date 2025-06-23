// Adds text color and background color pickers to Trix toolbar

if (!window.trixColorPickerInitialized) {
  window.trixColorPickerInitialized = true;

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
    if (group.querySelector('.trix-color-input')) return;

    // create text color picker
    const colorInput = document.createElement('input');
    colorInput.type = 'color';
    colorInput.className = 'trix-button trix-color-input';
    colorInput.title = 'Text Color';
    colorInput.addEventListener('input', function() {
      editor.activateAttribute('color', this.value);
    });

    // create background color picker
    const bgInput = document.createElement('input');
    bgInput.type = 'color';
    bgInput.className = 'trix-button trix-bgcolor-input';
    bgInput.title = 'Background Color';
    bgInput.addEventListener('input', function() {
      editor.activateAttribute('backgroundColor', this.value);
    });

    group.appendChild(colorInput);
    group.appendChild(bgInput);
  });
}
