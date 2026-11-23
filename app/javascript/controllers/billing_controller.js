import { Controller } from "@hotwired/stimulus"

// Settings › Billing (SCRUM-71): the dialogs say what the choice will charge
// before it is made, the country names the VAT number and its VAT, the
// automatic top-up saves itself, and a button that waits on Stripe says so
// at once.
export default class extends Controller {
  static targets = ["planSummary", "topUpSummary", "payButton", "vatLabel", "vatNote"]
  static values = { vatRate: Number, vatLabel: String, card: String }

  pickPlan(event) {
    if (this.hasPlanSummaryTarget) this.planSummaryTarget.textContent = event.target.dataset.summary
  }

  pickAmount(event) {
    const net = Number(event.target.value)
    const gross = net * (1 + this.vatRateValue / 100)
    const vat = this.vatRateValue > 0 ? ` + ${this.vatLabelValue}` : `, ${this.vatLabelValue}`
    this.topUpSummaryTarget.innerHTML =
      `Charged now to ${this.escape(this.cardValue)}: <b class="font-semibold">${this.money(gross)}</b> (${this.money(net)}${vat}). The invoice goes to every admin.`
    this.payButtonTarget.textContent = `Pay ${this.money(gross)}`
  }

  pickCountry(event) {
    const country = event.target.value
    const eu = (event.target.dataset.eu || "").split(" ")
    if (country === "PL") {
      this.vatLabelTarget.textContent = "NIP"
      this.vatNoteTarget.textContent = "Polish company: invoices carry 23% VAT."
    } else if (eu.includes(country)) {
      this.vatLabelTarget.textContent = "EU VAT NUMBER"
      this.vatNoteTarget.textContent = "EU business with a valid EU VAT number: reverse charge, no Polish VAT."
    } else {
      this.vatLabelTarget.textContent = "TAX ID (OPTIONAL)"
      this.vatNoteTarget.textContent = "Outside the EU: invoices are not subject to Polish VAT."
    }
  }

  submitForm(event) {
    event.target.form.requestSubmit()
  }

  // The submit button says what is happening and can't be pressed twice.
  busy(event) {
    const button = event.submitter || event.target.querySelector("[type=submit], button:not([type=button])")
    if (!button) return
    if (button.dataset.busyText) button.textContent = button.dataset.busyText
    setTimeout(() => { button.disabled = true }, 0)
  }

  money(amount) {
    return "$" + amount.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })
  }

  escape(text) {
    const span = document.createElement("span")
    span.textContent = text || "the card"
    return span.innerHTML
  }
}
