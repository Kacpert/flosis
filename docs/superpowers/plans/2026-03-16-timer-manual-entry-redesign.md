# Timer Manual Entry Redesign — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Redesign the manual time entry form with a themed date picker, separate 24h start/end time inputs, and triangular start/end/duration calculation with overnight support.

**Architecture:** Replace the single `datetime_local_field` + display-only end time with three independent inputs (date button + start time + end time) plus an editable duration field. A rewritten Stimulus `manual_entry_controller` handles the triangular calculation logic. Flatpickr is used date-only with CSS variable theming. Hidden fields assemble full datetimes for form submission.

**Tech Stack:** Rails 8.1, Stimulus JS, Flatpickr (date-only), Tailwind CSS with CSS custom properties.

**Spec:** `docs/superpowers/specs/2026-03-16-timer-manual-entry-redesign.md`

---

## Chunk 1: Core JS Controller + Flatpickr Theming

### Task 1: Rewrite manual_entry_controller.js with triangular logic

**Files:**
- Rewrite: `app/javascript/controllers/manual_entry_controller.js`

- [ ] **Step 1: Write the new manual_entry_controller.js**

Replace the entire file with the new controller that handles triangular calculation, time input formatting, and overnight detection.

```javascript
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "startTime", "endTime", "duration",
    "startDate", "endDate",
    "startedAt", "stoppedAt",
    "dateButton", "overnightBadge", "endDateWrap"
  ]

  connect() {
    this.endDateOverride = null // explicit end date set by user, or null
    this.syncHiddenFields()

    // Prevent form submission without a valid stopped_at
    this.element.closest("form")?.addEventListener("submit", (e) => {
      this.syncHiddenFields()
      if (this.hasStoppedAtTarget && !this.stoppedAtTarget.value) {
        e.preventDefault()
        // Flash the end time or duration input to indicate what's missing
        const target = this.hasEndTimeTarget ? this.endTimeTarget : this.durationTarget
        if (target) {
          target.style.borderColor = "var(--color-error)"
          setTimeout(() => { target.style.borderColor = "" }, 2000)
        }
      }
    })
  }

  // --- Event handlers (called from data-action) ---

  startTimeChanged() {
    this.formatTimeInput(this.startTimeTarget)
    if (this.hasEndTimeValue()) {
      this.recalcDuration()
    } else if (this.hasDurationValue()) {
      this.recalcEndTime()
    }
    this.updateOvernight()
    this.syncHiddenFields()
  }

  endTimeChanged() {
    this.formatTimeInput(this.endTimeTarget)
    if (this.hasStartTimeValue()) {
      this.recalcDuration()
    } else if (this.hasDurationValue()) {
      this.recalcStartTime()
    }
    this.updateOvernight()
    this.syncHiddenFields()
  }

  durationChanged() {
    const raw = this.durationTarget.value.trim()
    if (!raw) {
      this.syncHiddenFields()
      return
    }
    const seconds = this.parseDuration(raw)
    if (seconds === null || seconds <= 0 || seconds > 86400) {
      this.durationTarget.value = ""
      this.syncHiddenFields()
      return
    }
    this.durationTarget.value = this.formatDuration(seconds)

    if (this.hasStartTimeValue()) {
      this.recalcEndTime()
    } else if (this.hasEndTimeValue()) {
      this.recalcStartTime()
    }
    this.updateOvernight()
    this.syncHiddenFields()
  }

  dateChanged() {
    // Called when flatpickr date changes — reset overnight override
    this.endDateOverride = null
    this.updateOvernight()
    this.syncHiddenFields()
    this.updateDateButtonText()
  }

  // Called when user clicks the +1d badge to open end date picker
  toggleEndDate(event) {
    event.preventDefault()
    if (this.hasEndDateWrapTarget) {
      this.endDateWrapTarget.classList.toggle("hidden")
    }
  }

  endDateChanged() {
    // User explicitly set an end date
    const endDateVal = this.endDateTarget.value
    const startDateVal = this.startDateTarget.value
    if (endDateVal && endDateVal !== startDateVal) {
      this.endDateOverride = endDateVal
    } else {
      this.endDateOverride = null
    }
    this.updateOvernight()
    this.syncHiddenFields()
  }

  // Keydown filter for time inputs — only digits and colon
  timeKeydown(event) {
    const allowed = ["Backspace", "Delete", "Tab", "Escape", "Enter",
                     "ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown",
                     ":", "Home", "End"]
    if (allowed.includes(event.key)) return
    if (/^\d$/.test(event.key)) return
    event.preventDefault()
  }

  // Keydown filter for duration — digits, colon, period
  durationKeydown(event) {
    const allowed = ["Backspace", "Delete", "Tab", "Escape", "Enter",
                     "ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown",
                     ":", ".", "Home", "End"]
    if (allowed.includes(event.key)) return
    if (/^\d$/.test(event.key)) return
    event.preventDefault()
  }

  // --- Time input formatting ---

  formatTimeInput(input) {
    const raw = input.value.trim().replace(/[^0-9:]/g, "")
    if (!raw) return

    let hours, minutes

    // "14:30" — already formatted
    const colonMatch = raw.match(/^(\d{1,2}):(\d{2})$/)
    if (colonMatch) {
      hours = parseInt(colonMatch[1])
      minutes = parseInt(colonMatch[2])
    }
    // "1430" — four digits
    else if (/^\d{4}$/.test(raw)) {
      hours = parseInt(raw.substring(0, 2))
      minutes = parseInt(raw.substring(2, 4))
    }
    // "930" — three digits (9:30)
    else if (/^\d{3}$/.test(raw)) {
      hours = parseInt(raw.substring(0, 1))
      minutes = parseInt(raw.substring(1, 3))
    }
    // "14" — two digits (14:00)
    else if (/^\d{1,2}$/.test(raw)) {
      hours = parseInt(raw)
      minutes = 0
    }
    // "2:" — with trailing colon
    else if (/^\d{1,2}:$/.test(raw)) {
      hours = parseInt(raw)
      minutes = 0
    }
    else {
      input.value = ""
      return
    }

    // Validate
    if (hours > 23 || minutes > 59) {
      input.value = ""
      return
    }

    input.value = `${String(hours).padStart(2, "0")}:${String(minutes).padStart(2, "0")}`
  }

  // --- Triangular calculation ---

  recalcDuration() {
    const startMinutes = this.parseTime(this.startTimeTarget.value)
    const endMinutes = this.parseTime(this.endTimeTarget.value)
    if (startMinutes === null || endMinutes === null) return

    let diff = endMinutes - startMinutes
    if (diff < 0) diff += 24 * 60 // overnight

    if (this.endDateOverride && this.hasStartDateTarget) {
      const startDate = new Date(this.startDateTarget.value)
      const endDate = new Date(this.endDateOverride)
      const daysDiff = Math.round((endDate - startDate) / (24 * 60 * 60 * 1000))
      if (daysDiff > 0) {
        diff = (daysDiff * 24 * 60) + (endMinutes - startMinutes)
      }
    }

    this.durationTarget.value = this.formatDuration(diff * 60)
  }

  recalcEndTime() {
    const startMinutes = this.parseTime(this.startTimeTarget.value)
    const durationSeconds = this.parseDuration(this.durationTarget.value)
    if (startMinutes === null || durationSeconds === null) return

    const endMinutes = startMinutes + Math.floor(durationSeconds / 60)
    const h = Math.floor((endMinutes % (24 * 60)) / 60)
    const m = endMinutes % 60
    this.endTimeTarget.value = `${String(h).padStart(2, "0")}:${String(m).padStart(2, "0")}`
  }

  recalcStartTime() {
    const endMinutes = this.parseTime(this.endTimeTarget.value)
    const durationSeconds = this.parseDuration(this.durationTarget.value)
    if (endMinutes === null || durationSeconds === null) return

    let startMinutes = endMinutes - Math.floor(durationSeconds / 60)
    if (startMinutes < 0) startMinutes += 24 * 60
    const h = Math.floor(startMinutes / 60)
    const m = startMinutes % 60
    this.startTimeTarget.value = `${String(h).padStart(2, "0")}:${String(m).padStart(2, "0")}`
  }

  // --- Overnight detection ---

  updateOvernight() {
    if (!this.hasOvernightBadgeTarget) return

    const startMinutes = this.parseTime(this.startTimeTarget.value)
    const endMinutes = this.parseTime(this.endTimeTarget.value)

    if (startMinutes === null || endMinutes === null) {
      this.overnightBadgeTarget.classList.add("hidden")
      return
    }

    const isOvernight = endMinutes < startMinutes || this.endDateOverride
    if (isOvernight) {
      let daysDiff = 1
      if (this.endDateOverride && this.hasStartDateTarget) {
        const startDate = new Date(this.startDateTarget.value)
        const endDate = new Date(this.endDateOverride)
        daysDiff = Math.round((endDate - startDate) / (24 * 60 * 60 * 1000))
      }
      this.overnightBadgeTarget.textContent = `+${daysDiff}d`
      this.overnightBadgeTarget.classList.remove("hidden")
    } else {
      this.overnightBadgeTarget.classList.add("hidden")
    }
  }

  // --- Hidden field sync (assemble full datetimes for submission) ---

  syncHiddenFields() {
    if (!this.hasStartedAtTarget || !this.hasStartDateTarget) return

    const startDate = this.startDateTarget.value
    const startTime = this.startTimeTarget.value
    const endTime = this.hasEndTimeTarget ? this.endTimeTarget.value : ""

    if (startDate && startTime && startTime.includes(":")) {
      this.startedAtTarget.value = `${startDate}T${startTime}`
    }

    if (this.hasStoppedAtTarget && endTime && endTime.includes(":")) {
      let endDate = startDate
      const startMinutes = this.parseTime(startTime)
      const endMinutes = this.parseTime(endTime)

      if (this.endDateOverride) {
        endDate = this.endDateOverride
      } else if (startMinutes !== null && endMinutes !== null && endMinutes < startMinutes) {
        // Auto next day
        const d = new Date(startDate)
        d.setDate(d.getDate() + 1)
        endDate = d.toISOString().split("T")[0]
      }

      this.stoppedAtTarget.value = `${endDate}T${endTime}`
    } else if (this.hasStoppedAtTarget) {
      this.stoppedAtTarget.value = ""
    }
  }

  updateDateButtonText() {
    if (!this.hasDateButtonTarget || !this.hasStartDateTarget) return
    const dateVal = this.startDateTarget.value
    if (!dateVal) return
    const date = new Date(dateVal + "T00:00:00")
    const day = date.getDate()
    const month = date.toLocaleDateString("en-US", { month: "short" })
    this.dateButtonTarget.textContent = `${day} ${month}`
  }

  // --- Parsing helpers ---

  parseTime(str) {
    if (!str) return null
    const match = str.match(/^(\d{2}):(\d{2})$/)
    if (!match) return null
    const h = parseInt(match[1])
    const m = parseInt(match[2])
    if (h > 23 || m > 59) return null
    return h * 60 + m
  }

  parseDuration(str) {
    if (!str) return null
    const colonMatch = str.match(/^(\d{1,3}):(\d{2})(?::(\d{2}))?$/)
    if (colonMatch) {
      const hours = parseInt(colonMatch[1])
      const minutes = parseInt(colonMatch[2])
      const seconds = colonMatch[3] ? parseInt(colonMatch[3]) : 0
      if (minutes >= 60 || seconds >= 60) return null
      return hours * 3600 + minutes * 60 + seconds
    }
    const decimalMatch = str.match(/^(\d{1,2})\.(\d{1,2})$/)
    if (decimalMatch) {
      return Math.round(parseFloat(str) * 3600)
    }
    const plainMatch = str.match(/^(\d{1,3})$/)
    if (plainMatch) {
      const num = parseInt(plainMatch[1])
      if (num <= 480) return num * 60
      return null
    }
    return null
  }

  formatDuration(totalSeconds) {
    const hours = Math.floor(totalSeconds / 3600)
    const minutes = Math.floor((totalSeconds % 3600) / 60)
    return `${hours}:${String(minutes).padStart(2, "0")}`
  }

  // --- Helpers ---

  hasStartTimeValue() {
    return this.hasStartTimeTarget && this.startTimeTarget.value.trim() !== ""
  }

  hasEndTimeValue() {
    return this.hasEndTimeTarget && this.endTimeTarget.value.trim() !== ""
  }

  hasDurationValue() {
    return this.hasDurationTarget && this.durationTarget.value.trim() !== ""
  }
}
```

- [ ] **Step 2: Verify file saved correctly**

Run: `node -c app/javascript/controllers/manual_entry_controller.js`
Expected: no syntax errors

- [ ] **Step 3: Commit**

```bash
git add app/javascript/controllers/manual_entry_controller.js
git commit -m "feat: rewrite manual_entry_controller with triangular calculation logic"
```

---

### Task 2: Update datepicker_controller.js for date-only button trigger

**Files:**
- Modify: `app/javascript/controllers/datepicker_controller.js`

- [ ] **Step 1: Rewrite datepicker_controller.js**

Add support for: button-triggered opening, date-only mode, firstDayOfWeek, and an `onChange` callback that dispatches a Stimulus event.

```javascript
import { Controller } from "@hotwired/stimulus"
import flatpickr from "flatpickr"

export default class extends Controller {
  static values = {
    enableTime: { type: Boolean, default: false },
    dateFormat: { type: String, default: "Y-m-d" },
    firstDayOfWeek: { type: Number, default: 1 },
    triggerButton: { type: String, default: "" } // CSS selector for external trigger button
  }

  connect() {
    const options = {
      enableTime: this.enableTimeValue,
      dateFormat: this.enableTimeValue ? "Y-m-d H:i" : this.dateFormatValue,
      time_24hr: true,
      allowInput: !this.triggerButtonValue,
      locale: { firstDayOfWeek: this.firstDayOfWeekValue },
      onChange: (_selectedDates, dateStr) => {
        this.dispatch("change", { detail: { date: dateStr } })
      }
    }

    this.picker = flatpickr(this.element, options)

    // If a trigger button is specified, wire up click to open
    if (this.triggerButtonValue) {
      this.triggerEl = document.querySelector(this.triggerButtonValue)
      if (this.triggerEl) {
        this.openHandler = (e) => { e.preventDefault(); this.picker.open() }
        this.triggerEl.addEventListener("click", this.openHandler)
      }
    }
  }

  disconnect() {
    if (this.triggerEl && this.openHandler) {
      this.triggerEl.removeEventListener("click", this.openHandler)
    }
    if (this.picker) {
      this.picker.destroy()
    }
  }
}
```

- [ ] **Step 2: Verify file saved correctly**

Run: `node -c app/javascript/controllers/datepicker_controller.js`
Expected: no syntax errors

- [ ] **Step 3: Commit**

```bash
git add app/javascript/controllers/datepicker_controller.js
git commit -m "feat: add button trigger and firstDayOfWeek to datepicker controller"
```

---

### Task 3: Add flatpickr theme overrides and time input styles to CSS

**Files:**
- Modify: `app/assets/tailwind/application.css`

- [ ] **Step 1: Add flatpickr theme overrides and new component classes**

Append these styles after the existing component styles in `application.css`. Find the right insertion point — after the existing flatpickr or form-related styles, or at the end of the component section.

```css
/* ─── Flatpickr Nordic Theme Override ─── */
.flatpickr-calendar {
  background: var(--color-surface-container) !important;
  border: 1px solid var(--color-outline-variant) !important;
  border-radius: var(--radius-md) !important;
  box-shadow: var(--shadow-3) !important;
  font-family: var(--font-sans) !important;
}

.flatpickr-months .flatpickr-month,
.flatpickr-current-month {
  color: var(--color-on-surface) !important;
  fill: var(--color-on-surface) !important;
}

.flatpickr-months .flatpickr-prev-month,
.flatpickr-months .flatpickr-next-month {
  color: var(--color-on-surface-variant) !important;
  fill: var(--color-on-surface-variant) !important;
}

.flatpickr-months .flatpickr-prev-month:hover,
.flatpickr-months .flatpickr-next-month:hover {
  color: var(--color-primary) !important;
  fill: var(--color-primary) !important;
}

span.flatpickr-weekday {
  color: var(--color-outline) !important;
  font-size: 11px !important;
  font-weight: 500 !important;
}

.flatpickr-day {
  color: var(--color-on-surface) !important;
  border-radius: var(--radius-sm) !important;
  font-size: 12px !important;
}

.flatpickr-day:hover {
  background: var(--color-surface-container-high) !important;
  border-color: transparent !important;
}

.flatpickr-day.today {
  border-color: var(--color-primary) !important;
}

.flatpickr-day.selected {
  background: var(--color-primary) !important;
  color: var(--color-on-primary) !important;
  border-color: var(--color-primary) !important;
}

.flatpickr-day.prevMonthDay,
.flatpickr-day.nextMonthDay {
  color: var(--color-on-surface-variant) !important;
}

.flatpickr-current-month input.cur-year,
.flatpickr-current-month .flatpickr-monthDropdown-months {
  color: var(--color-on-surface) !important;
  background: transparent !important;
  font-weight: 600 !important;
}

/* ─── Timer Time Input ─── */
.m3-time-input {
  background: var(--color-surface-container);
  border: 1px solid var(--color-outline-variant);
  border-radius: var(--radius-sm);
  padding: 4px 8px;
  color: var(--color-on-surface);
  font-family: var(--font-mono);
  font-size: 14px;
  font-weight: 500;
  letter-spacing: 0.5px;
  width: 60px;
  text-align: center;
  outline: none;
  transition: border-color 0.15s;
}

.m3-time-input:focus {
  border-color: var(--color-primary);
}

.m3-time-input::placeholder {
  color: var(--color-outline);
}

/* ─── Timer Date Button ─── */
.m3-date-btn {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  padding: 4px 10px;
  border-radius: var(--radius-sm);
  background: var(--color-surface-container-low);
  border: 1px solid var(--color-outline-variant);
  color: var(--color-on-surface);
  font-size: 13px;
  font-weight: 500;
  cursor: pointer;
  transition: background 0.15s, border-color 0.15s;
}

.m3-date-btn:hover {
  background: var(--color-surface-container);
  border-color: var(--color-outline);
}

.m3-date-btn svg {
  color: var(--color-primary);
}

/* ─── Timer Duration Pill ─── */
.m3-duration-pill {
  background: var(--color-primary-container);
  border-radius: var(--radius-sm);
  padding: 4px 10px;
  color: var(--color-on-primary-container);
  font-family: var(--font-mono);
  font-size: 14px;
  font-weight: 600;
  text-align: center;
  width: 64px;
  border: none;
  outline: none;
}

.m3-duration-pill:focus {
  box-shadow: 0 0 0 2px var(--color-primary);
}

.m3-duration-pill::placeholder {
  color: var(--color-on-primary-container);
  opacity: 0.5;
}

/* ─── Overnight Badge ─── */
.m3-overnight-badge {
  background: var(--color-tertiary-container);
  color: var(--color-on-tertiary-container);
  font-size: 10px;
  font-weight: 600;
  padding: 2px 6px;
  border-radius: var(--radius-xs);
  cursor: pointer;
  transition: background 0.15s;
}

.m3-overnight-badge:hover {
  opacity: 0.8;
}
```

- [ ] **Step 2: Verify CSS is valid**

Run: `tail -5 app/assets/tailwind/application.css`
Expected: shows the last few lines of the new CSS

- [ ] **Step 3: Commit**

```bash
git add app/assets/tailwind/application.css
git commit -m "feat: add flatpickr theme overrides and time input component styles"
```

---

## Chunk 2: Timer Bar View + Controller Cleanup

### Task 4: Rewrite the manual mode section of _timer_bar.html.erb

**Files:**
- Modify: `app/views/shared/_timer_bar.html.erb` (lines 119–169, the manual mode section)

- [ ] **Step 1: Replace the manual mode section**

Replace the entire `<%# Manual mode %>` div (lines 120–168) with the new layout. Keep the timer mode section (lines 61–117) unchanged.

The new manual mode HTML:

```erb
    <%# Manual mode %>
    <div data-timer-mode-target="manualMode" class="hidden">
      <%= form_with url: time_entries_path, method: :post, class: "flex items-center gap-2 w-full", data: { controller: "jira-task-search manual-entry" } do |f| %>
        <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4 flex-shrink-0" style="color: var(--color-outline)" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="1.75"><path stroke-linecap="round" stroke-linejoin="round" d="M16.862 4.487l1.687-1.688a1.875 1.875 0 112.652 2.652L10.582 16.07a4.5 4.5 0 01-1.897 1.13L6 18l.8-2.685a4.5 4.5 0 011.13-1.897l8.932-8.931z" /></svg>
        <div class="relative flex-1 min-w-[100px]">
          <%= f.text_field "time_entry[description]", placeholder: "What did you work on?",
              class: "bg-transparent border-none w-full text-[0.9375rem] focus:outline-none",
              style: "color: var(--color-on-surface)",
              autocomplete: "off",
              data: { action: "focus->jira-task-search#focus input->jira-task-search#filter keydown->jira-task-search#keydown", jira_task_search_target: "input" } %>
          <%= f.hidden_field "time_entry[task_id]", data: { jira_task_search_target: "taskId" } %>
          <div class="hidden absolute left-0 top-full mt-1 w-full rounded-xl shadow-lg z-[9999] max-h-64 overflow-y-auto" style="background: var(--color-surface-container); border: 1px solid var(--color-outline-variant); min-width: 320px;" data-jira-task-search-target="dropdown">
            <div data-jira-task-search-target="list"></div>
          </div>
        </div>
        <div class="h-5 w-px timer-desktop-only" style="background: var(--color-outline-variant)"></div>
        <div class="timer-desktop-only">
          <%= f.select "time_entry[project_id]",
              options_from_collection_for_select(available_projects, :id, :name),
              { include_blank: "Project" },
              class: "m3-timer-pill",
              data: { controller: "task-loader", action: "change->task-loader#load change->jira-task-search#projectChanged change->remember-project#save" } %>
        </div>
        <div class="timer-desktop-only" data-jira-task-select>
          <%= f.select "time_entry[task_id]", [],
              { include_blank: "Task" },
              class: "m3-timer-pill" %>
        </div>
        <div class="h-5 w-px timer-desktop-only" style="background: var(--color-outline-variant)"></div>

        <%# Date/Time inputs %>
        <div class="flex items-center gap-1.5 timer-desktop-only">
          <%# Date button + hidden flatpickr input %>
          <button type="button" class="m3-date-btn" id="manual-date-trigger" data-manual-entry-target="dateButton">
            <svg xmlns="http://www.w3.org/2000/svg" class="h-3.5 w-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="1.75"><path stroke-linecap="round" stroke-linejoin="round" d="M6.75 3v2.25M17.25 3v2.25M3 18.75V7.5a2.25 2.25 0 012.25-2.25h13.5A2.25 2.25 0 0121 7.5v11.25m-18 0A2.25 2.25 0 005.25 21h13.5A2.25 2.25 0 0021 18.75m-18 0v-7.5A2.25 2.25 0 015.25 9h13.5A2.25 2.25 0 0121 11.25v7.5" /></svg>
            <%= Time.current.strftime("%-d %b") %>
            <svg xmlns="http://www.w3.org/2000/svg" class="h-2.5 w-2.5" style="color: var(--color-outline)" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2.5"><path stroke-linecap="round" stroke-linejoin="round" d="M19.5 8.25l-7.5 7.5-7.5-7.5" /></svg>
          </button>
          <input type="hidden" value="<%= Time.current.strftime('%Y-%m-%d') %>"
                 data-controller="datepicker"
                 data-datepicker-trigger-button-value="#manual-date-trigger"
                 data-datepicker-first-day-of-week-value="1"
                 data-manual-entry-target="startDate"
                 data-action="datepicker:change->manual-entry#dateChanged">

          <%# Start time %>
          <input type="text" placeholder="<%= Time.current.strftime('%H:%M') %>"
                 value="<%= Time.current.strftime('%H:%M') %>"
                 class="m3-time-input"
                 maxlength="5"
                 data-manual-entry-target="startTime"
                 data-action="blur->manual-entry#startTimeChanged keydown->manual-entry#timeKeydown">

          <%# Arrow %>
          <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4 flex-shrink-0" style="color: var(--color-outline)" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="1.75"><path stroke-linecap="round" stroke-linejoin="round" d="M13.5 4.5L21 12m0 0l-7.5 7.5M21 12H3" /></svg>

          <%# End time %>
          <input type="text" placeholder="--:--"
                 class="m3-time-input"
                 maxlength="5"
                 data-manual-entry-target="endTime"
                 data-action="blur->manual-entry#endTimeChanged keydown->manual-entry#timeKeydown">

          <%# Overnight badge (hidden by default) %>
          <span class="m3-overnight-badge hidden"
                data-manual-entry-target="overnightBadge"
                data-action="click->manual-entry#toggleEndDate">+1d</span>

          <%# End date picker (hidden, shown only when overnight badge is clicked) %>
          <div class="hidden" data-manual-entry-target="endDateWrap">
            <input type="hidden"
                   data-controller="datepicker"
                   data-datepicker-first-day-of-week-value="1"
                   data-manual-entry-target="endDate"
                   data-action="datepicker:change->manual-entry#endDateChanged">
          </div>
        </div>

        <div class="h-5 w-px timer-desktop-only" style="background: var(--color-outline-variant)"></div>

        <%# Duration %>
        <input type="text" placeholder="0:00"
               class="m3-duration-pill timer-desktop-only"
               maxlength="7"
               data-manual-entry-target="duration"
               data-action="blur->manual-entry#durationChanged keydown->manual-entry#durationKeydown">

        <%# Hidden fields for form submission %>
        <%= f.hidden_field "time_entry[started_at]", value: Time.current.strftime("%Y-%m-%dT%H:%M"), data: { manual_entry_target: "startedAt" } %>
        <%= f.hidden_field "time_entry[stopped_at]", value: "", data: { manual_entry_target: "stoppedAt" } %>

        <button type="button" class="m3-icon-btn m3-icon-btn-sm" data-action="click->timer-mode#toggle" title="Timer mode">
          <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="1.75"><path stroke-linecap="round" stroke-linejoin="round" d="M5.25 5.653c0-.856.917-1.398 1.667-.986l11.54 6.348a1.125 1.125 0 010 1.971l-11.54 6.347a1.125 1.125 0 01-1.667-.985V5.653z" /></svg>
        </button>

        <button type="submit" class="m3-fab" style="background: var(--color-success); color: var(--color-on-success);">Save</button>
      <% end %>
    </div>
```

- [ ] **Step 2: Verify ERB syntax**

Run: `ruby -rerb -e "ERB.new(File.read('app/views/shared/_timer_bar.html.erb')).src" 2>&1 | head -5`
Expected: no syntax errors

- [ ] **Step 3: Commit**

```bash
git add app/views/shared/_timer_bar.html.erb
git commit -m "feat: replace timer bar manual mode with date button + start/end time inputs"
```

---

### Task 5: Clean up time_entries_controller.rb

**Files:**
- Modify: `app/controllers/time_entries_controller.rb`

- [ ] **Step 1: Remove handle_manual_duration and parse_duration**

Remove the `handle_manual_duration` call from `create` (line 44) and `update` (line 64). Remove the `handle_manual_duration` method (lines 137–144) and `parse_duration` method (lines 146–161).

After removal, the `create` method should be:

```ruby
  def create
    @time_entry = current_workspace.time_entries.build(time_entry_params)
    @time_entry.user = current_user

    if @time_entry.save
      # ... existing respond_to block unchanged
    end
  end
```

And `update` should be:

```ruby
  def update
    if @time_entry.update(time_entry_params)
      # ... existing respond_to block unchanged
    end
  end
```

The `time_entry_params` method already permits `:started_at` and `:stopped_at`, so no changes needed there.

- [ ] **Step 2: Run existing tests**

Run: `bin/rails test test/models/time_entry_test.rb`
Expected: All 5 tests pass (the tests don't test duration_manual parsing)

- [ ] **Step 3: Commit**

```bash
git add app/controllers/time_entries_controller.rb
git commit -m "refactor: remove handle_manual_duration — forms now submit started_at + stopped_at"
```

---

## Chunk 3: Edit Forms Update

### Task 6: Update _form.html.erb (new/edit page form)

**Files:**
- Modify: `app/views/time_entries/_form.html.erb`

- [ ] **Step 1: Replace the date/time fields section**

Replace the grid with `datetime_local_field`s and `duration_manual` (lines 30–46) with the new date + time inputs:

```erb
  <div class="grid grid-cols-1 md:grid-cols-4 gap-4" data-controller="manual-entry">
    <div class="space-y-1">
      <label class="text-sm font-medium" style="color: var(--color-on-surface-variant)">Date</label>
      <input type="text" class="m3-text-field w-full"
             value="<%= time_entry.started_at&.strftime('%Y-%m-%d') || Date.current.to_s %>"
             data-controller="datepicker"
             data-datepicker-first-day-of-week-value="1"
             data-manual-entry-target="startDate"
             data-action="datepicker:change->manual-entry#dateChanged"
             readonly>
    </div>

    <div class="space-y-1">
      <label class="text-sm font-medium" style="color: var(--color-on-surface-variant)">Start Time</label>
      <input type="text" class="m3-text-field w-full"
             value="<%= time_entry.started_at&.strftime('%H:%M') %>"
             placeholder="09:00" maxlength="5"
             data-manual-entry-target="startTime"
             data-action="blur->manual-entry#startTimeChanged keydown->manual-entry#timeKeydown">
    </div>

    <div class="space-y-1">
      <label class="text-sm font-medium" style="color: var(--color-on-surface-variant)">End Time</label>
      <div class="flex items-center gap-2">
        <input type="text" class="m3-text-field flex-1"
               value="<%= time_entry.stopped_at&.strftime('%H:%M') %>"
               placeholder="--:--" maxlength="5"
               data-manual-entry-target="endTime"
               data-action="blur->manual-entry#endTimeChanged keydown->manual-entry#timeKeydown">
        <span class="m3-overnight-badge hidden" data-manual-entry-target="overnightBadge"
              data-action="click->manual-entry#toggleEndDate">+1d</span>
      </div>
      <div class="hidden" data-manual-entry-target="endDateWrap">
        <input type="text" class="m3-text-field w-full mt-1" placeholder="End date"
               value="<%= time_entry.stopped_at&.to_date != time_entry.started_at&.to_date ? time_entry.stopped_at&.strftime('%Y-%m-%d') : '' %>"
               data-controller="datepicker"
               data-datepicker-first-day-of-week-value="1"
               data-manual-entry-target="endDate"
               data-action="datepicker:change->manual-entry#endDateChanged"
               readonly>
      </div>
    </div>

    <div class="space-y-1">
      <label class="text-sm font-medium" style="color: var(--color-on-surface-variant)">Duration</label>
      <input type="text" class="m3-text-field w-full"
             placeholder="0:00" maxlength="7"
             value="<%= time_entry.persisted? && time_entry.duration_seconds.to_i > 0 ? "#{time_entry.duration_seconds.to_i / 3600}:#{format('%02d', (time_entry.duration_seconds.to_i % 3600) / 60)}" : '' %>"
             data-manual-entry-target="duration"
             data-action="blur->manual-entry#durationChanged keydown->manual-entry#durationKeydown">
    </div>

    <%# Hidden fields for actual submission %>
    <%= f.hidden_field :started_at, data: { manual_entry_target: "startedAt" } %>
    <%= f.hidden_field :stopped_at, data: { manual_entry_target: "stoppedAt" } %>
  </div>
```

- [ ] **Step 2: Verify ERB syntax**

Run: `ruby -rerb -e "ERB.new(File.read('app/views/time_entries/_form.html.erb')).src" 2>&1 | head -5`
Expected: no syntax errors

- [ ] **Step 3: Commit**

```bash
git add app/views/time_entries/_form.html.erb
git commit -m "feat: update time entry edit form with date/time inputs and triangular calc"
```

---

### Task 7: Update _time_entry_row.html.erb inline edit

**Files:**
- Modify: `app/views/time_entries/_time_entry_row.html.erb` (lines 73–92, the edit mode section)

- [ ] **Step 1: Replace the inline edit form datetime fields**

Replace the two `datetime_local_field` lines (87–88) with the new compact time inputs. The inline edit should use `manual-entry` controller for triangular calc. Replace the edit form section (lines 75–91):

```erb
        <%= form_with model: entry, url: time_entry_path(entry), method: :patch, class: "flex items-center gap-2 flex-wrap w-full", data: { action: "keydown->inline-edit#submitOnEnter", controller: "manual-entry" } do |f| %>
          <%= f.text_field :description, placeholder: "Description",
              class: "m3-input-compact flex-1 min-w-[120px]" %>
          <%= f.collection_select :project_id,
              available_projects, :id, :name,
              { include_blank: "No project" },
              class: "m3-input-compact",
              data: { controller: "task-loader", action: "change->task-loader#load" } %>
          <%= f.collection_select :task_id,
              (entry.project ? entry.project.tasks.active : []), :id, :name,
              { include_blank: "No task" },
              class: "m3-input-compact" %>
          <input type="text" value="<%= entry.started_at.strftime('%Y-%m-%d') %>"
                 class="m3-input-compact w-[100px]"
                 data-controller="datepicker"
                 data-datepicker-first-day-of-week-value="1"
                 data-manual-entry-target="startDate"
                 data-action="datepicker:change->manual-entry#dateChanged"
                 readonly>
          <input type="text" value="<%= entry.started_at.strftime('%H:%M') %>"
                 class="m3-input-compact w-[60px] text-center" style="font-family: var(--font-mono)"
                 maxlength="5"
                 data-manual-entry-target="startTime"
                 data-action="blur->manual-entry#startTimeChanged keydown->manual-entry#timeKeydown">
          <span style="color: var(--color-outline)">→</span>
          <input type="text" value="<%= entry.stopped_at.strftime('%H:%M') %>"
                 class="m3-input-compact w-[60px] text-center" style="font-family: var(--font-mono)"
                 maxlength="5"
                 data-manual-entry-target="endTime"
                 data-action="blur->manual-entry#endTimeChanged keydown->manual-entry#timeKeydown">
          <span class="m3-overnight-badge hidden" data-manual-entry-target="overnightBadge"
                data-action="click->manual-entry#toggleEndDate">+1d</span>
          <div class="hidden" data-manual-entry-target="endDateWrap">
            <input type="hidden"
                   data-controller="datepicker"
                   data-datepicker-first-day-of-week-value="1"
                   data-manual-entry-target="endDate"
                   data-action="datepicker:change->manual-entry#endDateChanged">
          </div>
          <%= f.hidden_field :started_at, data: { manual_entry_target: "startedAt" } %>
          <%= f.hidden_field :stopped_at, data: { manual_entry_target: "stoppedAt" } %>
          <%= f.submit "Save", class: "m3-btn m3-btn-filled m3-btn-sm" %>
          <button type="button" class="m3-btn m3-btn-text m3-btn-sm" data-action="click->inline-edit#cancel">Cancel</button>
        <% end %>
```

- [ ] **Step 2: Verify ERB syntax**

Run: `ruby -rerb -e "ERB.new(File.read('app/views/time_entries/_time_entry_row.html.erb')).src" 2>&1 | head -5`
Expected: no syntax errors

- [ ] **Step 3: Commit**

```bash
git add app/views/time_entries/_time_entry_row.html.erb
git commit -m "feat: update inline edit row with 24h time inputs and triangular calc"
```

---

## Chunk 4: Manual Testing + Display Time Format

### Task 8: Update time display to 24h format

**Files:**
- Modify: `app/views/time_entries/_time_entry_row.html.erb` (line 41)

- [ ] **Step 1: Confirm display already uses 24h format**

Check line 41 of `_time_entry_row.html.erb`:
```erb
<%= entry.started_at.strftime("%H:%M") %> – <%= is_running ? "now" : entry.stopped_at.strftime("%H:%M") %>
```

This already uses `%H:%M` (24h format). No change needed — this step is a verification only.

- [ ] **Step 2: Run full test suite**

Run: `bin/rails test`
Expected: All tests pass

- [ ] **Step 3: Start the dev server and manually verify**

Run: `bin/rails server` (if not already running)

Manual verification checklist:
1. Open the time entries page
2. Toggle to manual entry mode
3. Verify date button shows "16 Mar" format and opens styled calendar
4. Verify start time shows 24h format (no AM/PM)
5. Enter a start time (e.g., "13:00") and end time (e.g., "15:30") → verify duration auto-calculates to "2:30"
6. Clear end time, enter duration "1:30" → verify end time auto-calculates to "14:30"
7. Clear start time, enter end time "15:00" and duration "2:00" → verify start auto-calculates to "13:00"
8. Enter start "23:00" and end "01:30" → verify "+1d" badge appears and duration shows "2:30"
9. Click Save → verify entry is created with correct times
10. Click Edit on an existing entry → verify inline edit shows 24h times
11. Switch themes (dark, purple-light, purple-dark) → verify calendar and inputs look correct in all themes

- [ ] **Step 4: Final commit if any fixes needed**

```bash
git add -A
git commit -m "fix: address issues found during manual testing"
```
