import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["input", "container"]
  static values = {
    url: String,
    current: { type: String, default: "" }
  }

  connect() {
    this.loadIndexers()
  }

  async loadIndexers() {
    try {
      const response = await fetch(this.urlValue, {
        headers: { "Accept": "application/json" }
      })

      if (!response.ok) {
        this.showFallback()
        return
      }

      const indexers = await response.json()

      if (indexers.length === 0) {
        this.showFallback()
        return
      }

      this.renderCheckboxes(indexers)
    } catch (error) {
      this.showFallback()
    }
  }

  renderCheckboxes(indexers) {
    const selected = this.currentValue
      .split(",")
      .map(s => s.trim().toLowerCase())
      .filter(s => s.length > 0)

    this.containerTarget.innerHTML = ""

    indexers.forEach(indexer => {
      const name = indexer.name
      const assignedTo = indexer.assigned_to
      const isSelected = selected.includes(name.toLowerCase())
      const isDisabled = assignedTo && !isSelected

      const label = document.createElement("label")
      label.className = `flex items-center gap-2 py-1 ${isDisabled ? "opacity-50" : "cursor-pointer"}`

      const checkbox = document.createElement("input")
      checkbox.type = "checkbox"
      checkbox.value = name
      checkbox.checked = isSelected
      checkbox.disabled = isDisabled
      checkbox.className = "rounded border-gray-600 bg-gray-800 text-blue-600 focus:ring-blue-500 focus:ring-offset-gray-900"
      checkbox.dataset.action = "change->indexer-preference#updateSelection"

      const span = document.createElement("span")
      span.className = `text-sm ${isDisabled ? "text-gray-500" : "text-gray-300"}`
      span.textContent = name

      label.appendChild(checkbox)
      label.appendChild(span)

      if (assignedTo && !isSelected) {
        const badge = document.createElement("span")
        badge.className = "text-xs text-gray-500 ml-1"
        badge.textContent = `(${assignedTo})`
        label.appendChild(badge)
      }

      this.containerTarget.appendChild(label)
    })
  }

  showFallback() {
    this.containerTarget.innerHTML = ""

    const input = document.createElement("input")
    input.type = "text"
    input.value = this.currentValue || ""
    input.placeholder = "e.g. MyAnonaMouse, IPTorrents"
    input.className = "block rounded-lg border border-gray-700 bg-gray-800 text-white placeholder-gray-500 focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-blue-500 px-4 py-3 w-full"
    input.dataset.action = "input->indexer-preference#updateFromText"

    const hint = document.createElement("p")
    hint.className = "mt-1 text-sm text-gray-500"
    hint.textContent = "Configure an indexer provider to see available indexers as checkboxes."

    this.containerTarget.appendChild(input)
    this.containerTarget.appendChild(hint)
  }

  updateSelection() {
    const checkboxes = this.containerTarget.querySelectorAll("input[type=checkbox]:checked")
    const names = Array.from(checkboxes).map(cb => cb.value)
    this.inputTarget.value = names.join(",")
  }

  updateFromText(event) {
    this.inputTarget.value = event.target.value
  }
}
