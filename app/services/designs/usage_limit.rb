# Claude's session and usage limits, as the CLI words them when a turn stops
# on one (Designs imports): "You've hit your session limit · resets 8am
# (Europe/Warsaw)", "… resets Nov 5, 8:30pm (…)", or the older "Claude AI usage
# limit reached|<epoch>". An import that hits one waits until it resets and
# goes on, instead of failing every feature after it.
module Designs::UsageLimit
  # How long an import waits when the reset cannot be read: a turn on a
  # limit that has not reset yet stops within seconds, so trying again is
  # cheap.
  FALLBACK = 30.minutes

  HIT = /hit your (?:[\w-]+ )?limit|usage limit reached|limit reached/i
  EPOCH = /limit reached\|(\d{9,})/i
  RESETS = /resets\s+(?:(?<month>[A-Z][a-z]{2})\s+(?<day>\d{1,2}),?\s+)?(?<hour>\d{1,2})(?::(?<minute>\d{2}))?\s*(?<half>am|pm)(?:\s*\((?<zone>[^)]+)\))?/i

  module_function

  def hit?(text)
    HIT.match?(text.to_s)
  end

  # When the limit text says it resets: the next such time after now, in the
  # zone it names (the app's own when it names none), else now + FALLBACK.
  def reset_at(text, now: Time.current)
    text = text.to_s
    return Time.zone.at(text[EPOCH, 1].to_i) if text.match?(EPOCH)

    match = RESETS.match(text) or return now + FALLBACK
    zone = ActiveSupport::TimeZone[match[:zone].to_s.strip] || Time.zone
    local = now.in_time_zone(zone)
    hour = match[:hour].to_i % 12 + (match[:half].casecmp?("pm") ? 12 : 0)
    minute = match[:minute].to_i
    if match[:month]
      month = Date::ABBR_MONTHNAMES.index(match[:month].capitalize) or return now + FALLBACK
      at = zone.local(local.year, month, match[:day].to_i, hour, minute)
      at < local - 1.day ? zone.local(local.year + 1, month, match[:day].to_i, hour, minute) : at
    else
      at = zone.local(local.year, local.month, local.day, hour, minute)
      at <= local ? at + 1.day : at
    end
  end
end
