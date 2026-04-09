import { Controller } from '@hotwired/stimulus'

// Maps trigger type radio buttons to routing_expression values.
// Shows/hides keyword input and advanced expression textarea based on selection.
export default class extends Controller {
  static targets = ['hiddenField', 'keywordInput', 'keywordGroup', 'advancedGroup', 'advancedInput']

  static values = {
    currentExpression: String
  }

  connect() {
    this.detectTriggerType()
    this.updateVisibility()
  }

  // Called when a radio button changes
  change() {
    this.updateVisibility()
    this.updateExpression()
  }

  // Called when keyword input changes
  keywordChanged() {
    // Strip double quotes to prevent Liquid injection
    const input = this.keywordInputTarget
    const sanitized = input.value.replace(/"/g, '')
    if (input.value !== sanitized) input.value = sanitized
    this.updateExpression()
  }

  // Called when advanced expression changes
  advancedChanged() {
    this.hiddenFieldTarget.value = this.advancedInputTarget.value
  }

  get selectedType() {
    const checked = this.element.querySelector('input[name="trigger_type"]:checked')
    return checked?.value || 'mention'
  }

  detectTriggerType() {
    const expr = (this.currentExpressionValue || '').trim()
    if (!expr || expr === 'chat.mentioned_user.id == agent.id') {
      this.selectRadio('mention')
    } else if (expr === 'event_name == "comment_created"') {
      this.selectRadio('auto')
    } else {
      const keywordMatch = expr.match(/^chat\.content\s+contains\s+"([^"]*)"$/)
      if (keywordMatch) {
        this.selectRadio('keyword')
        this.keywordInputTarget.value = keywordMatch[1]
      } else {
        this.selectRadio('advanced')
        this.advancedInputTarget.value = expr
      }
    }
  }

  selectRadio(value) {
    const radio = this.element.querySelector(`input[name="trigger_type"][value="${value}"]`)
    if (radio) radio.checked = true
  }

  updateVisibility() {
    const type = this.selectedType
    this.keywordGroupTarget.style.display = type === 'keyword' ? '' : 'none'
    this.advancedGroupTarget.style.display = type === 'advanced' ? '' : 'none'
  }

  updateExpression() {
    const type = this.selectedType
    let expression = ''

    switch (type) {
      case 'auto':
        expression = 'event_name == "comment_created"'
        break
      case 'mention':
        expression = 'chat.mentioned_user.id == agent.id'
        break
      case 'keyword': {
        const keyword = this.keywordInputTarget.value.trim().replace(/"/g, '')
        expression = keyword ? `chat.content contains "${keyword}"` : ''
        break
      }
      case 'advanced':
        expression = this.advancedInputTarget.value
        break
    }

    this.hiddenFieldTarget.value = expression
  }
}
