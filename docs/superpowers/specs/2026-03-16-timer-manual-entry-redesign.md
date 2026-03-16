# Timer Manual Entry Redesign

## Summary

Redesign the manual time entry form in the timer bar to support:
- A better-looking date picker (themed flatpickr, date-only)
- Separate editable start time and end time inputs in 24h format
- Triangular calculation: any two of start/end/duration determine the third
- Overnight work support with automatic +1d detection
- Theme-aware styling using CSS custom properties (works across all 4 themes)

## Current State

The manual entry mode in `_timer_bar.html.erb` has:
- A `datetime_local_field` for start time (browser native picker, shows AM/PM)
- A duration input (`H:MM` format)
- A display-only end time label (auto-calculated, not editable)
- Flatpickr is used but with default unstyled appearance

Issues:
- AM/PM format instead of 24h
- End time is not editable — user can't enter "I worked from X to Y"
- The native datetime picker looks out of place with the Nordic design
- No overnight work support

## Design

### Timer Bar Layout (Manual Mode)

```
[✏️] [What did you work on?] | [Project ▾] [Task ▾] | [📅 16 Mar] [13:26] → [15:30] | [2:04] [▶] [Save]
```

Components left to right:
1. **Edit mode icon** (existing)
2. **Description input** (existing, unchanged)
3. **Divider**
4. **Project/Task selectors** (existing, unchanged)
5. **Divider**
6. **Date button** — compact "16 Mar" format, clicking opens themed flatpickr calendar dropdown
7. **Start time input** — editable `HH:MM`, 24h format
8. **Arrow icon** — visual separator (→)
9. **End time input** — editable `HH:MM`, 24h format
10. **Divider**
11. **Duration display/input** — editable `H:MM`, highlighted in primary-container color
12. **Timer mode toggle** (existing)
13. **Save button** (existing)

### Date Picker

- Flatpickr in **date-only mode** (no time component)
- Opens as dropdown below the date button
- Config: `dateFormat: "Y-m-d"`, `allowInput: false`, `locale: { firstDayOfWeek: 1 }` (locale added as new Stimulus value on datepicker controller)
- "Today" shortcut at bottom of calendar
- Calendar icon in primary color as visual anchor
- Chevron indicator on the button

### Time Inputs

Custom `HH:MM` text inputs (not flatpickr):
- Only digits and colon allowed (keydown filter)
- Auto-format on blur:
  - `"930"` → `"09:30"`
  - `"14"` → `"14:00"`
  - `"2:"` → `"02:00"`
  - `"1430"` → `"14:30"`
- Invalid input handling on blur: if hour > 23 or minute > 59 or unparseable, reset field to empty string
- Styled as compact boxes with surface-container background and outline-variant border
- Monospace font (JetBrains Mono / SF Mono)
- Width constrained to ~60px

### Initial State

When the user toggles into manual mode:
- **Start time**: pre-filled with current time (HH:MM, 24h)
- **End time**: empty
- **Duration**: empty
- **Date**: today's date

### Triangular Calculation Logic

The controller tracks `lastEdited` to know which field to recalculate:

**On start time change (`blur`):**
- If end time has a value → recalculate duration = end - start
- Else if duration has a value → recalculate end = start + duration

**On end time change (`blur`):**
- If start time has a value → recalculate duration = end - start
- Else if duration has a value → recalculate start = end - duration

**On duration change (`blur`):**
- If start time has a value → recalculate end = start + duration
- Else if end time has a value → recalculate start = end - duration

### Overnight Support

- **Detection:** When end time < start time (e.g., start 23:00, end 01:30), automatically treat end as next day
- **Visual indicator:** A `+1d` badge appears next to the end time input (small green pill)
- **Override:** The `+1d` badge is clickable — opens a separate end date flatpickr to override the auto-assumed date (e.g., for multi-day spans like Friday 23:00 → Sunday 02:00 = +2d)
- **Default:** No end date picker shown unless overnight is detected and user clicks the badge
- **Badge updates:** Shows `+1d`, `+2d`, etc. based on the actual date difference

### Overnight Badge + End Date Override

When the user has explicitly set an end date override (via the +1d badge picker), subsequent changes to start/end time inputs do NOT re-trigger overnight auto-detection. The explicit override is "sticky" until:
- The user clears the override by clicking the badge again and selecting the same date as start
- The user changes the start date (resets override)

### Form Submission

- Hidden fields: `time_entry[started_at]` and `time_entry[stopped_at]` (full ISO datetime)
- Assembled from: start date + start time, end date + end time
- The JS controller assembles these before form submission
- **Minimum required to submit:** start date + start time + at least one of (end time, duration). If the user enters start + duration, the controller calculates end and populates `stopped_at`. If only start time with no end or duration, form validation prevents submission.
- `duration_manual` is removed from the form — the server always receives `started_at` and `stopped_at`

### Date Button → Flatpickr Trigger

The date button is a styled `<button>` element. Flatpickr is initialized on a hidden `<input>` adjacent to the button, using flatpickr's `wrap: false` mode. The button's click handler calls `this.picker.open()` programmatically. The hidden input holds the date value in `Y-m-d` format. The button's visible text is updated via JS when the date changes (formatted as "16 Mar").

### Theme Support

All styling uses CSS custom properties — no hardcoded colors:

| Element | CSS Variable |
|---------|-------------|
| Time input background | `var(--color-surface-container)` |
| Time input border | `var(--color-outline-variant)` |
| Time input text | `var(--color-on-surface)` |
| Date button background | `var(--color-surface-container-low)` |
| Date button text | `var(--color-on-surface)` |
| Calendar icon | `var(--color-primary)` |
| Duration background | `var(--color-primary-container)` |
| Duration text | `var(--color-on-primary-container)` |
| +1d badge background | `var(--color-tertiary-container)` |
| +1d badge text | `var(--color-on-tertiary-container)` |
| Arrow icon | `var(--color-outline)` |
| Flatpickr calendar bg | `var(--color-surface-container)` |
| Flatpickr selected day | `var(--color-primary)` / `var(--color-on-primary)` |
| Flatpickr day text | `var(--color-on-surface)` |
| Flatpickr prev month | `var(--color-on-surface-variant)` |
| Flatpickr header | `var(--color-on-surface)` |
| Flatpickr today link | `var(--color-primary)` |

This ensures the picker looks correct across all 4 themes (default, dark, purple-light, purple-dark).

## Files Changed

1. **`app/views/shared/_timer_bar.html.erb`** — Replace `datetime_local_field` with date button + start/end time inputs + hidden datetime fields
2. **`app/javascript/controllers/manual_entry_controller.js`** — Rewrite with triangular calculation, time formatting, overnight detection
3. **`app/javascript/controllers/datepicker_controller.js`** — Add date-only mode support, configure for calendar button trigger
4. **`app/assets/tailwind/application.css`** — Add flatpickr theme overrides using CSS variables, time input styles, +1d badge styles
5. **`app/controllers/time_entries_controller.rb`** — Ensure `stopped_at` is accepted in strong params (partially exists), handle both duration_manual and stopped_at submission
6. **`app/views/time_entries/_form.html.erb`** — Update edit form with same date/time input pattern
7. **`app/views/time_entries/_time_entry_row.html.erb`** — Update inline edit row: use start/end time HH:MM inputs and duration, but keep it compact (no separate date button — use the existing date from the entry, editable via a small flatpickr trigger if needed)

## Notes

- The existing `time_entry[workspace_id]` hidden field with empty value in the manual form is dead code (not in strong params) — remove it during implementation.
- The `datepicker_controller.js` needs a new `firstDayOfWeek` Stimulus value to pass locale config to flatpickr.

## Out of Scope

- Mobile-specific time picker (uses existing responsive hiding)
- Timer mode changes (only manual entry mode is affected)
- Time zone handling (uses server time zone as-is)
