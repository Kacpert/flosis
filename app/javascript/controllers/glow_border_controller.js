import { Controller } from "@hotwired/stimulus"

// Animates a subtle light sweep around the border of a container.
// A small bright segment travels slowly along the border edge.
export default class extends Controller {
  connect() {
    this.angle = Math.random() * 360
    this.speed = 0.5 // degrees per frame (~30°/s → full rotation in ~12s)

    const overlay = document.createElement("div")
    overlay.style.cssText = `
      position: absolute;
      inset: 0;
      border-radius: inherit;
      pointer-events: none;
      z-index: 4;
    `
    this.overlay = overlay
    this.element.appendChild(overlay)

    this.tick = this.tick.bind(this)
    this.raf = requestAnimationFrame(this.tick)
  }

  tick() {
    this.angle = (this.angle + this.speed) % 360
    this.overlay.style.boxShadow = this.buildShadow(this.angle)
    this.raf = requestAnimationFrame(this.tick)
  }

  // Maps angle (0-360) to a position along the border perimeter
  // and creates a soft inset shadow at that point
  buildShadow(angle) {
    const rad = angle * Math.PI / 180
    // Map angle to approximate border position using sin/cos
    const x = Math.cos(rad)
    const y = Math.sin(rad)

    const offsetX = (x * 6).toFixed(1)
    const offsetY = (y * 6).toFixed(1)

    return `inset ${offsetX}px ${offsetY}px 6px -2px rgba(160,140,230,0.18)`
  }

  disconnect() {
    if (this.raf) cancelAnimationFrame(this.raf)
    this.overlay?.remove()
  }
}
