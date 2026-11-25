import CommonPopupController from './common_popup_controller'

export default class extends CommonPopupController {
    connect() {
        super.connect()
        this._allItems = []
        this._onInputBound = this._onInput.bind(this)
        this._onKeydownBound = this.handleInputKeydown.bind(this)
        this._onCloseBound = () => this.close()
        this.inputTarget.addEventListener('input', this._onInputBound)
        this.inputTarget.addEventListener('keydown', this._onKeydownBound)
        this.closeTarget.addEventListener('click', this._onCloseBound)
    }

    disconnect() {
        this.inputTarget?.removeEventListener('input', this._onInputBound)
        this.inputTarget?.removeEventListener('keydown', this._onKeydownBound)
        this.closeTarget?.removeEventListener('click', this._onCloseBound)
        super.disconnect()
    }

    updateListItems(items) {
        const activeItem = this.popup.items[this.popup.activeIndex]
        this._allItems = items
        this._onInput()
        if (!activeItem) return
        const activeIndex = this.popup.items.findIndex(item => String(item.id) === String(activeItem.id))
        if (activeIndex >= 0) this.popup.setActiveIndex(activeIndex)
    }
}
