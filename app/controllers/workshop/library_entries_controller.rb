# The design library (Designs::Library) for Flosis staff: the base prompt, the
# skills and the style packs every design turn runs on. Saving an entry's text
# makes a new version and restoring an old one makes another, so history is
# never rewritten, and nothing is deleted: turns record the versions they ran
# on. Everyone else gets a 404, so the area's existence is not confirmed. The
# library is one for all of Flosis; the Workshop shell only lends it a layout.
class Workshop::LibraryEntriesController < Workshop::BaseController
  include FlosisStaffOnly
  skip_before_action :require_current_project! # one library for all of Flosis
  before_action :set_entry, only: %i[show edit update restore]

  HEADINGS = { "base_prompt" => "Base prompt", "skill" => "Skills", "style_pack" => "Style packs" }.freeze

  def index
    entries = LibraryEntry.order(:name).to_a
    @groups = HEADINGS.map { |kind, heading| [ heading, kind, entries.select { |entry| entry.kind == kind } ] }
  end

  def show
    @versions = @entry.library_entry_versions.reorder(number: :desc).includes(:created_by)
  end

  def new
    @entry = LibraryEntry.new(kind: params[:kind].presence_in(LibraryEntry::KINDS) || "skill")
    @body = ""
  end

  def create
    @entry = LibraryEntry.new(entry_params.merge(params.require(:library_entry).permit(:kind, :key)))
    if save_with_body
      flash[:clar_toast] = "#{@entry.name} added to the library"
      redirect_to workshop_library_entry_path(@entry)
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @body = @entry.current_version&.body.to_s
  end

  def update
    @entry.assign_attributes(entry_params)
    if save_with_body
      flash[:clar_toast] = "#{@entry.name} saved"
      redirect_to workshop_library_entry_path(@entry)
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def restore
    version = @entry.library_entry_versions.find(params[:version_id])
    restored = @entry.restore!(version, by: current_user)
    flash[:clar_toast] = "Version #{version.number} restored as version #{restored.number}"
    redirect_to workshop_library_entry_path(@entry), status: :see_other
  end

  private

  def set_entry
    @entry = LibraryEntry.find(params[:id])
  end

  # The key and the kind are set once, at creation: a project names its style
  # pack by key, and what an entry is does not change under the turns that
  # used it.
  def entry_params
    params.require(:library_entry).permit(:name, :description, :active)
  end

  # The entry and its text, saved together or not at all. Text the current
  # version already has makes no new version (LibraryEntry#revise!).
  def save_with_body
    @body = params.dig(:library_entry, :body).to_s
    LibraryEntry.transaction do
      @entry.save!
      @entry.revise!(body: @body, by: current_user)
    end
    true
  rescue ActiveRecord::RecordInvalid => e
    @entry.errors.add(:base, "The text can't be blank") if e.record.is_a?(LibraryEntryVersion)
    false
  end
end
