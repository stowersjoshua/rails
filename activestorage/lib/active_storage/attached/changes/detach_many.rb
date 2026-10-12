# frozen_string_literal: true

module ActiveStorage
  class Attached::Changes::DetachMany # :nodoc:
    attr_reader :name, :record, :attachments

    def initialize(name, record, attachments)
      @name, @record, @attachments = name, record, attachments
    end

    def detach
      if attachments.any?
        if attachments.respond_to?(:delete_all)
          if detach_callbacks?
            ActiveStorage::Attachment.transaction { attachments.each(&:delete_with_detach_callbacks) }
            attachments.reset
          else
            attachments.delete_all
          end
        end

        record.attachment_changes.delete(name)
      end
    end

    private
      # Deleting the attachments one at a time lets each run its callbacks, so
      # it is only done when the record has detach callbacks for them.
      def detach_callbacks?
        record.attachment_reflections[name]&.detach_callbacks?
      end
  end
end
