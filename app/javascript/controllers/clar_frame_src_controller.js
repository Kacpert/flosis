import { Controller } from "@hotwired/stimulus"

// Sets a turbo-frame's src to reload it in place — used by the developer-report
// modal's range tabs (1m..2y). Plain links inside the frame promote to a
// full-page visit; setting the frame src is always an in-place frame nav, so
// the modal content swaps without leaving the page.
//
// Usage: put data-controller="clar-frame-src" data-clar-frame-src-frame-value="<frame-id>"
// on a container, and on each tab:
//   data-action="click->clar-frame-src#load" data-clar-frame-src-url-param="<url>"
export default class extends Controller {
  static values = { frame: String }

  load(event) {
    event.preventDefault()
    const url = event.params.url
    const frame = document.getElementById(this.frameValue)
    if (frame && url) frame.setAttribute("src", url)
  }
}
