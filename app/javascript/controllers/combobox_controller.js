import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["input", "dropdown", "list", "hidden"]
  static values = { options: Array }

  connect() {
    // Build options array from existing children or from value
    if (!this.hasOptionsValue || this.optionsValue.length === 0) {
      // Try to read from a sibling select
      const select = this.element.querySelector("select")
      if (select) {
        this.options = Array.from(select.options).map(opt => ({
          value: opt.value,
          text: opt.text
        })).filter(opt => opt.value)

        // Store the current value
        this.currentValue = select.value
        this.currentText = select.options[select.selectedIndex]?.text || ""

        // Hide the original select
        select.style.display = "none"
        select.removeAttribute("name")

        // Set initial input value
        if (this.hasInputTarget) {
          this.inputTarget.value = this.currentText === select.options[0]?.text ? "" : this.currentText
        }
        if (this.hasHiddenTarget) {
          this.hiddenTarget.value = this.currentValue
        }
      }
    } else {
      this.options = this.optionsValue
    }

    this.renderList()

    // Close on click outside
    this.clickOutside = this.clickOutside.bind(this)
    document.addEventListener("click", this.clickOutside)
  }

  disconnect() {
    document.removeEventListener("click", this.clickOutside)
  }

  filter() {
    const query = this.inputTarget.value.toLowerCase()
    this.renderList(query)
    this.show()
  }

  renderList(query = "") {
    if (!this.hasListTarget) return

    const filtered = query
      ? this.options.filter(opt => opt.text.toLowerCase().includes(query))
      : this.options

    this.listTarget.innerHTML = ""

    // Add "clear" option
    const clearItem = document.createElement("li")
    clearItem.innerHTML = `<a class="text-base-content/50 text-sm">None</a>`
    clearItem.addEventListener("click", () => this.select("", ""))
    this.listTarget.appendChild(clearItem)

    filtered.forEach(opt => {
      const li = document.createElement("li")
      li.innerHTML = `<a>${opt.text}</a>`
      li.addEventListener("click", () => this.select(opt.value, opt.text))
      this.listTarget.appendChild(li)
    })
  }

  select(value, text) {
    this.inputTarget.value = text
    if (this.hasHiddenTarget) {
      this.hiddenTarget.value = value
    }
    this.hide()

    // Trigger change event on hidden input for task-loader etc.
    this.hiddenTarget.dispatchEvent(new Event("change", { bubbles: true }))
  }

  show() {
    if (this.hasDropdownTarget) {
      this.dropdownTarget.classList.remove("hidden")
    }
  }

  hide() {
    if (this.hasDropdownTarget) {
      this.dropdownTarget.classList.add("hidden")
    }
  }

  clickOutside(event) {
    if (!this.element.contains(event.target)) {
      this.hide()
    }
  }

  focus() {
    this.renderList()
    this.show()
  }
}
