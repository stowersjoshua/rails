# frozen_string_literal: true

require "active_support/core_ext/module/delegation"

# = Active Storage \Attachment
#
# Attachments associate records with blobs. Usually that's a one record-many blobs relationship,
# but it is possible to associate many different records with the same blob. A foreign-key constraint
# on the attachments table prevents blobs from being purged if they’re still attached to any records.
#
# Attachments also have access to all methods from ActiveStorage::Blob.
#
# If you wish to preload attachments or blobs, you can use these scopes:
#
#   # preloads attachments, their corresponding blobs, and variant records (if using `ActiveStorage.track_variants`)
#   User.all.with_attached_avatars
#
#   # preloads blobs and variant records (if using `ActiveStorage.track_variants`)
#   User.first.avatars.with_all_variant_records
class ActiveStorage::Attachment < ActiveStorage::Record
  define_model_callbacks :upload

  after_upload :mirror_blob_later
  after_upload :analyze_blob_later
  after_upload :create_variants
  after_upload :run_after_attach_callbacks

  # Set to true when immediate variants have been processed from local io,
  # so create_variants knows to skip them.
  attr_accessor :immediate_variants_processed

  # Set to true for fresh uploads (io provided), false for existing blobs.
  # Used to determine whether to run :upload callbacks in after_create_commit.
  attr_accessor :pending_upload

  ##
  # :method:
  #
  # Returns the associated record.
  belongs_to :record, polymorphic: true, touch: ActiveStorage.touch_attachment_records

  ##
  # :method:
  #
  # Returns the associated ActiveStorage::Blob.
  belongs_to :blob, class_name: "ActiveStorage::Blob", autosave: true, inverse_of: :attachments

  delegate_missing_to :blob
  delegate :signed_id, to: :blob

  before_create :run_before_attach_callbacks
  after_create_commit :run_upload_callbacks, unless: :pending_upload

  before_destroy :run_before_detach_callbacks
  after_destroy_commit :purge_dependent_blob_and_run_after_detach_callbacks

  ##
  # :singleton-method:
  #
  # Eager load all variant records on an attachment at once.
  #
  #   User.first.avatars.with_all_variant_records
  scope :with_all_variant_records, -> { includes(blob: {
    variant_records: { image_attachment: :blob },
    preview_image_attachment: { blob: { variant_records: { image_attachment: :blob } } }
  }) }

  # Called by Attached::Changes::CreateOne to handle the upload workflow for
  # fresh uploads. Processes immediate variants and analyzes from the local io
  # (avoiding a download round-trip), uploads the blob, then runs the :upload
  # callbacks.
  #
  # For existing blob attachments, the :upload callbacks are run via
  # after_create_commit instead.
  def uploaded(io:)
    blob.local_io = io

    process_immediate_variants_from_io(io)
    analyze_blob_from_io(io)

    io.rewind if io.respond_to?(:rewind)
    blob.upload_without_unfurling(io)

    # Persist analysis metadata if the blob was already saved (happens when
    # upload runs in after_commit, after the blob was saved via autosave).
    blob.save! if blob.persisted? && blob.metadata_changed?

    run_upload_callbacks
  ensure
    blob.local_io = nil
  end

  # Synchronously deletes the attachment and {purges the blob}[rdoc-ref:ActiveStorage::Blob#purge].
  def purge
    delete_with_detach_callbacks(touch_record: true) { blob&.purge }
  end

  # Deletes the attachment and {enqueues a background job}[rdoc-ref:ActiveStorage::Blob#purge_later] to purge the blob.
  def purge_later
    delete_with_detach_callbacks(touch_record: true) { blob&.purge_later }
  end

  # Deletes the attachment without running its destroy callbacks, as +purge+,
  # +purge_later+ and +detach+ do, but with the record's detach callbacks:
  # +before_detach+ runs in the same transaction as the deletion, and
  # +after_detach+ once it is committed, after the given block.
  def delete_with_detach_callbacks(touch_record: false) # :nodoc:
    detach_callbacks = persisted? && detach_callbacks?

    if detach_callbacks || touch_record
      transaction do
        run_before_detach_callbacks if detach_callbacks
        delete
        record.touch if touch_record && record&.persisted?
      end
    else
      delete
    end

    # A before_detach callback can roll the transaction back without raising.
    return unless destroyed?

    yield if block_given?
    self.class.current_transaction.after_commit { run_after_detach_callbacks } if detach_callbacks
  end

  # Returns an ActiveStorage::Variant or ActiveStorage::VariantWithRecord
  # instance for the attachment with the set of +transformations+ provided.
  # Example:
  #
  #   avatar.variant(resize_to_limit: [100, 100]).processed.url
  #
  # or if you are using pre-defined variants:
  #
  #   avatar.variant(:thumb).processed.url
  #
  # See ActiveStorage::Blob::Representable#variant for more information.
  #
  # Raises an +ArgumentError+ if +transformations+ is a +Symbol+ which is an
  # unknown pre-defined variant of the attachment.
  def variant(transformations)
    transformations = transformations_by_name(transformations)
    blob.variant(transformations)
  end

  # Returns an ActiveStorage::Preview instance for the attachment with the set
  # of +transformations+ provided.
  # Example:
  #
  #   video.preview(resize_to_limit: [100, 100]).processed.url
  #
  # or if you are using pre-defined variants:
  #
  #   video.preview(:thumb).processed.url
  #
  # See ActiveStorage::Blob::Representable#preview for more information.
  #
  # Raises an +ArgumentError+ if +transformations+ is a +Symbol+ which is an
  # unknown pre-defined variant of the attachment.
  def preview(transformations)
    transformations = transformations_by_name(transformations)
    blob.preview(transformations)
  end

  # Returns an ActiveStorage::Preview or an ActiveStorage::Variant for the
  # attachment with set of +transformations+ provided.
  # Example:
  #
  #   avatar.representation(resize_to_limit: [100, 100]).processed.url
  #
  # or if you are using pre-defined variants:
  #
  #   avatar.representation(:thumb).processed.url
  #
  # See ActiveStorage::Blob::Representable#representation for more information.
  #
  # Raises an +ArgumentError+ if +transformations+ is a +Symbol+ which is an
  # unknown pre-defined variant of the attachment.
  def representation(transformations)
    transformations = transformations_by_name(transformations)
    blob.representation(transformations)
  end

  private
    def run_before_attach_callbacks
      run_record_callbacks(:before_attach)
    end

    def run_after_attach_callbacks
      run_record_callbacks(:after_attach)
    end

    def run_before_detach_callbacks
      run_record_callbacks(:before_detach)
    end

    def run_after_detach_callbacks
      run_record_callbacks(:after_detach)
    end

    # Runs the attach and detach callbacks the record declared for this
    # attachment, the same way association callbacks are run.
    def run_record_callbacks(callback_name)
      callbacks = record_reflection&.callbacks_for(callback_name) || []

      callbacks.each do |callback|
        case callback
        when Symbol
          record.send(callback, self)
        when Proc
          callback.call(record, self)
        else
          callback.send(callback_name, record, self)
        end
      end
    end

    def detach_callbacks?
      record_reflection&.detach_callbacks?
    end

    def record_reflection
      record.attachment_reflections[name] if record
    end

    # Purges the blob before running the after_detach callbacks, so that one
    # raising an exception can't leave the blob behind.
    def purge_dependent_blob_and_run_after_detach_callbacks
      purge_dependent_blob
      run_after_detach_callbacks
    end

    def run_upload_callbacks
      run_callbacks(:upload)
    end

    def analyze_blob_later
      blob.analyze_later unless blob.analyzed? || skip_later_analysis?
    end

    def analyze_blob_from_io(io)
      return if blob.analyzed? || skip_later_analysis?

      io.rewind if io.respond_to?(:rewind)
      blob.analyze_without_saving
    end

    def skip_later_analysis?
      (analyze_option || ActiveStorage.analyze) == :lazily
    end

    def analyze_option
      record.attachment_reflections[name]&.options&.fetch(:analyze, nil)
    end

    def mirror_blob_later
      blob.mirror_later
    end

    def process_immediate_variants_from_io(io)
      return unless blob.variable?

      named_variants.each do |_variant_name, named_variant|
        next unless named_variant.process(record) == :immediately

        blob.variant(named_variant.transformations).process_from_io(io)
        io.rewind if io.respond_to?(:rewind)
      end

      self.immediate_variants_processed = true
    end

    def create_variants
      return unless representable?

      immediate_variants = []
      later_variants     = []

      named_variants.each do |_name, named_variant|
        case named_variant.process(record)
        when :immediately
          # Skip if already processed from local io in uploaded()
          immediate_variants << named_variant.transformations unless immediate_variants_processed
        when :later
          later_variants << named_variant.transformations
        end
      end

      ActiveStorage::CreateVariantsJob.perform_now(blob, variants: immediate_variants, process: :immediately) if immediate_variants.any?
      ActiveStorage::CreateVariantsJob.perform_later(blob, variants: later_variants, process: :later) if later_variants.any?
    end

    def purge_dependent_blob
      if dependent == :purge_later
        blob&.purge_later
      elsif dependent == :purge
        blob&.purge
      end
    end

    def dependent
      record.attachment_reflections[name]&.options&.fetch(:dependent, nil)
    end

    def named_variants
      record.attachment_reflections[name]&.named_variants || {}
    end

    def transformations_by_name(transformations)
      case transformations
      when Symbol
        variant_name = transformations
        named_variants.fetch(variant_name) do
          record_model_name = record.to_model.model_name.name
          raise ArgumentError, "Cannot find variant :#{variant_name} for #{record_model_name}##{name}"
        end.transformations
      else
        transformations
      end
    end
end

ActiveSupport.run_load_hooks :active_storage_attachment, ActiveStorage::Attachment
