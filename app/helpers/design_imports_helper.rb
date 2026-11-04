# Designs imports, as the mockups beside the design draw them: the Imports
# line in the Designs list, each import's entry, and the cards of an import's
# page, worst first, each saying in plain words what happened.
module DesignImportsHelper
  # The order the cards come in: what only the person can unblock first,
  # then what could not finish, then what Claude's limit stopped, then the
  # reviews.
  CARD_ORDER = { waiting: 0, error: 1, unreadable: 1, limit: 2, paused: 2, review: 3 }.freeze

  # The Imports line: lit while an import has settled since the person last
  # opened it; on its right "N need you" while any card waits, else the date of
  # the last import.
  def import_line(project, user)
    waiting = DesignSetupFeature.needs_you.where(design_setup_id: project.design_setups.select(:id)).count
    last = project.design_setups.maximum(:created_at)
    { lit: DesignSetup.lit_for?(project, user), right: waiting.positive? ? "#{waiting} need you" : last&.in_time_zone&.strftime("%b %-d") }
  end

  # Where an import's page is: in Designs once master exists, else on the
  # setup page, which shows a first import until it lands.
  def import_page_path(setup)
    return workshop_design_setup_run_path unless setup.project.designs_ready? && !(setup.first? && !setup.done?)

    workshop_designs_overview_path(tab: "imports", import: setup.id)
  end

  # The import a new one would start from: the last first import or resync
  # that is over, once master has the designs; nil before.
  def import_resync_from(project)
    return unless project.designs_ready?

    project.design_setups.where(kind: %w[first resync], status: "approved").where.not(finished_at: nil).order(:id).last
  end

  # Whether the person can act on the import's cards here: a re-import's are
  # fixed on its thread.
  def import_actions?(setup)
    can?(:configuration) && !setup.reimport?
  end

  def import_cards(setup)
    setup.needs_you.to_a.sort_by { |feature| [ CARD_ORDER.fetch(feature.problem, 4), feature.position ] }
  end

  # "Finished today at 06:50", "Nov 3, 01:40–06:50", "Started today at 01:40".
  def import_when(setup, range: false)
    started = setup.created_at.in_time_zone
    ended = setup.finished_at&.in_time_zone
    day = ->(time) { time.to_date == Time.zone.today ? "today" : time.strftime("%b %-d") }
    return "Started #{day.(started)} at #{started.strftime('%H:%M')}" unless ended
    return "#{started.strftime('%b %-d')}, #{started.strftime('%H:%M')}–#{ended.strftime('%H:%M')}" if range

    "Finished #{day.(ended)} at #{ended.strftime('%H:%M')}"
  end

  # "as Admin, Product Owner, Product Manager".
  def import_contexts(project)
    names = project.design_setup_roles.order(:position).map(&:name)
    "as #{names.join(', ')}" if names.any?
  end

  def import_card_label(feature)
    case feature.problem
    when :waiting then "Waiting for you"
    when :review then "Review what comes in"
    when :limit, :paused then "Not started"
    else "Couldn't finish"
    end
  end

  # The theme's tone for the card's border and its label.
  def import_card_tone(feature)
    case feature.problem
    when :waiting then "warn"
    when :review then "ai"
    when :limit, :paused then "muted"
    else "danger"
    end
  end

  # What happened, in plain words.
  def import_card_text(feature)
    case feature.problem
    when :waiting then feature.question.to_s
    when :review then "Developers changed this feature's code. Part of its design came from a thread, so nothing lands on master until you decide."
    when :unreadable then "The AI's answer could not be read."
    when :limit
      stopped = (feature.finished_at || feature.updated_at).in_time_zone
      resets = Designs::UsageLimit.reset_at(feature.error, now: stopped).in_time_zone
      "Claude's session limit ran out at #{stopped.strftime('%H:%M')} (it resets at #{resets.strftime('%H:%M')})."
    when :paused then "Claude's session limit stopped it. The import goes on by itself at #{feature.resets_at.in_time_zone.strftime('%H:%M')}."
    else feature.error.to_s.truncate(300).presence || "Claude could not finish this feature."
    end
  end

  # A built feature's line: "6 screens · 9 new, 4 reused · 4 notes".
  def import_built_line(feature)
    screens = feature.screens.size
    components = [ ("#{feature.components_new} new" if feature.components_new.positive?),
                   ("#{feature.components_reused} reused" if feature.components_reused.positive?) ].compact.join(", ").presence
    notes = feature.notes.size
    [ ("#{screens} #{screens == 1 ? 'screen' : 'screens'}" if screens.positive?), components,
      ("#{notes} #{notes == 1 ? 'note' : 'notes'}" if notes.positive?) ].compact.join(" · ")
  end

  # A proposal's first screen, on its branch and on master, for the review
  # card's "Open screens: proposed · master"; nil when it changes no screen.
  def import_review_links(feature)
    path = Array(feature.review["paths"]).find { |file| file.start_with?("designs/") && file.count("/") == 2 } or return
    project = feature.design_setup.project
    publisher = Designs::Publisher.new(project, Designs::Repo.new(project))
    { proposed: (publisher.grant_url(feature.branch, path) if feature.branch), master: publisher.grant_url(Designs::Repo::MASTER, path) }
  rescue Designs::Publisher::Error, ArgumentError
    nil
  end

  # Where Open takes a built feature: the first screen its turn's commit
  # wrote, on master's canvas; nil when that cannot be told.
  def import_open_path(repo, feature)
    sha = feature.design_turn&.commit_sha or return
    path = repo.files_changed_in(sha, "designs/", lock: false).find { |file| file.count("/") == 2 && !file.end_with?(".changes.html") } or return
    _, context, file = path.split("/")
    workshop_designs_overview_path(ctx: context, screen: file.delete_suffix(".html"))
  end
end
