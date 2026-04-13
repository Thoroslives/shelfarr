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

    const html = indexers.map(name => {
      const checked = selected.includes(name.toLowerCase()) ? "checked" : ""
      const id = `indexer_${name.replace(/[^a-zA-Z0-9]/g, "_")}`
      return `
        <label class="flex items-center gap-2 py-1 cursor-pointer" for="${id}">
          <input type="checkbox" id="${id}" value="${name}" ${checked}
                 class="rounded border-gray-600 bg-gray-800 text-blue-600 focus:ring-blue-500 focus:ring-offset-gray-900"
                 data-action="change->indexer-preference#updateSelection">
          <span class="text-gray-300 text-sm">${name}</span>
        </label>
      `
    }).join("")

    this.containerTarget.innerHTML = html
  }

  showFallback() {
    this.containerTarget.innerHTML = `
      <input type="text" value="${this.currentValue || ""}"
             placeholder="e.g. MyAnonaMouse, IPTorrents"
             class="block rounded-lg border border-gray-700 bg-gray-800 text-white placeholder-gray-500 focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-blue-500 px-4 py-3 w-full"
             data-action="input->indexer-preference#updateFromText">
      <p class="mt-1 text-sm text-gray-500">Configure an indexer provider to see available indexers as checkboxes.</p>
    `
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
