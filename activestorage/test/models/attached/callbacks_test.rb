# frozen_string_literal: true

require "test_helper"
require "database/setup"

class ActiveStorage::AttachedCallbacksTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  class Member < ActiveRecord::Base
    self.table_name = "users"

    cattr_accessor :events, default: []

    class Recorder
      def self.before_attach(member, attachment)
        member.log(:object_before_attach, attachment)
      end

      def self.after_attach(member, attachment)
        member.log(:object_after_attach, attachment)
      end
    end

    has_one_attached :avatar, before_attach: :log_before_attach, after_attach: :log_after_attach,
      before_detach: :log_before_detach, after_detach: :log_after_detach

    has_many_attached :photos, before_attach: :log_before_attach, after_attach: :log_after_attach,
      before_detach: :log_before_detach, after_detach: :log_after_detach

    has_one_attached :resume,
      before_attach: ->(member, attachment) { member.log(:before_attach, attachment, persisted: attachment.persisted?) },
      after_attach: ->(member, attachment) { member.log(:after_attach, attachment, uploaded: attachment.service.exist?(attachment.key)) },
      before_detach: ->(member, attachment) { member.log(:before_detach, attachment, exists: ActiveStorage::Attachment.exists?(attachment.id)) },
      after_detach: ->(member, attachment) { member.log(:after_detach, attachment, exists: ActiveStorage::Attachment.exists?(attachment.id)) }

    has_one_attached :badge, before_attach: Recorder, after_attach: [Recorder, :log_after_attach]

    has_one_attached :contract, before_attach: ->(*) { raise ArgumentError, "rejected" }
    has_one_attached :license, before_detach: ->(*) { raise ArgumentError, "kept" }
    has_one_attached :certificate, dependent: :purge, after_detach: ->(*) { raise ArgumentError, "too late" }
    has_one_attached :draft, before_detach: ->(*) { raise ActiveRecord::Rollback }, after_detach: :log_after_detach

    def log(event, attachment, **details)
      events << [event, attachment.name, attachment.filename.to_s, *details.values]
    end

    private
      def log_before_attach(attachment)
        log(:before_attach, attachment)
      end

      def log_after_attach(attachment)
        log(:after_attach, attachment)
      end

      def log_before_detach(attachment)
        log(:before_detach, attachment)
      end

      def log_after_detach(attachment)
        log(:after_detach, attachment)
      end
  end

  class SpecialMember < Member; end

  setup do
    Member.events = []
    @member = Member.create!(name: "Josh")
  end

  teardown do
    ActiveStorage::Blob.all.each(&:delete)
  end

  test "attaching a new file to a has_one_attached runs its attach callbacks" do
    @member.avatar.attach(io: StringIO.new("STUFF"), filename: "town.jpg")

    assert_equal [[:before_attach, "avatar", "town.jpg"], [:after_attach, "avatar", "town.jpg"]], Member.events
  end

  test "attaching an existing blob to a has_one_attached runs its attach callbacks" do
    @member.avatar.attach(create_blob(filename: "funky.jpg"))

    assert_equal [[:before_attach, "avatar", "funky.jpg"], [:after_attach, "avatar", "funky.jpg"]], Member.events
  end

  test "attaching files when creating a record runs the attach callbacks" do
    Member.create!(name: "Jason", avatar: create_blob(filename: "funky.jpg"))

    assert_equal [[:before_attach, "avatar", "funky.jpg"], [:after_attach, "avatar", "funky.jpg"]], Member.events
  end

  test "before_attach runs before the attachment is saved" do
    @member.resume.attach(create_blob(filename: "resume.pdf"))

    assert_includes Member.events, [:before_attach, "resume", "resume.pdf", false]
  end

  test "after_attach runs once a new file has been uploaded" do
    @member.resume.attach(io: StringIO.new("STUFF"), filename: "resume.pdf")

    assert_includes Member.events, [:after_attach, "resume", "resume.pdf", true]
  end

  test "attaching a directly uploaded blob runs the attach callbacks" do
    @member.avatar.attach(directly_upload_file_blob(filename: "racecar.jpg").signed_id)

    assert_equal [[:before_attach, "avatar", "racecar.jpg"], [:after_attach, "avatar", "racecar.jpg"]], Member.events
  end

  test "attaching files to a has_many_attached runs the attach callbacks for each file" do
    @member.photos.attach(
      { io: StringIO.new("STUFF"), filename: "town.jpg" },
      { io: StringIO.new("IT"), filename: "country.jpg" }
    )

    assert_equal [
      [:before_attach, "photos", "town.jpg"],
      [:before_attach, "photos", "country.jpg"],
      [:after_attach, "photos", "town.jpg"],
      [:after_attach, "photos", "country.jpg"]
    ], Member.events
  end

  test "attaching more files to a has_many_attached runs the attach callbacks only for the new files" do
    @member.photos.attach(create_blob(filename: "funky.jpg"))
    Member.events.clear

    @member.photos.attach(create_blob(filename: "town.jpg"))

    assert_equal [[:before_attach, "photos", "town.jpg"], [:after_attach, "photos", "town.jpg"]], Member.events
  end

  test "attach callbacks accept objects and arrays" do
    @member.badge.attach(create_blob(filename: "badge.png"))

    assert_equal [
      [:object_before_attach, "badge", "badge.png"],
      [:object_after_attach, "badge", "badge.png"],
      [:after_attach, "badge", "badge.png"]
    ], Member.events
  end

  test "an exception from before_attach prevents the attachment" do
    assert_raises(ArgumentError, match: "rejected") do
      @member.contract.attach(create_blob(filename: "contract.pdf"))
    end

    assert_not @member.reload.contract.attached?
  end

  test "after_attach does not run when the attachment is rolled back" do
    Member.transaction do
      @member.avatar.attach(create_blob(filename: "funky.jpg"))
      raise ActiveRecord::Rollback
    end

    assert_equal [[:before_attach, "avatar", "funky.jpg"]], Member.events
  end

  test "destroying an attachment runs its detach callbacks" do
    @member.avatar.attach(create_blob(filename: "funky.jpg"))
    Member.events.clear

    @member.avatar_attachment.destroy

    assert_equal [[:before_detach, "avatar", "funky.jpg"], [:after_detach, "avatar", "funky.jpg"]], Member.events
  end

  test "before_detach runs before the attachment is removed and after_detach after" do
    @member.resume.attach(create_blob(filename: "resume.pdf"))
    Member.events.clear

    @member.resume.detach

    assert_equal [[:before_detach, "resume", "resume.pdf", true], [:after_detach, "resume", "resume.pdf", false]], Member.events
  end

  test "purging a has_one_attached runs its detach callbacks" do
    @member.avatar.attach(create_blob(filename: "funky.jpg"))
    Member.events.clear

    @member.avatar.purge

    assert_equal [[:before_detach, "avatar", "funky.jpg"], [:after_detach, "avatar", "funky.jpg"]], Member.events
  end

  test "purging a has_one_attached later runs its detach callbacks" do
    @member.avatar.attach(create_blob(filename: "funky.jpg"))
    Member.events.clear

    @member.avatar.purge_later

    assert_equal [[:before_detach, "avatar", "funky.jpg"], [:after_detach, "avatar", "funky.jpg"]], Member.events
  end

  test "detaching a has_one_attached runs its detach callbacks" do
    @member.avatar.attach(create_blob(filename: "funky.jpg"))
    Member.events.clear

    @member.avatar.detach

    assert_equal [[:before_detach, "avatar", "funky.jpg"], [:after_detach, "avatar", "funky.jpg"]], Member.events
    assert_not @member.reload.avatar.attached?
  end

  test "replacing a has_one_attached runs the detach callbacks for the old file and the attach callbacks for the new one" do
    @member.avatar.attach(create_blob(filename: "funky.jpg"))
    Member.events.clear

    @member.avatar.attach(create_blob(filename: "town.jpg"))

    assert_equal [
      [:before_detach, "avatar", "funky.jpg"],
      [:before_attach, "avatar", "town.jpg"],
      [:after_detach, "avatar", "funky.jpg"],
      [:after_attach, "avatar", "town.jpg"]
    ], Member.events
  end

  test "assigning nil to a has_one_attached runs its detach callbacks" do
    @member.avatar.attach(create_blob(filename: "funky.jpg"))
    Member.events.clear

    @member.update!(avatar: nil)

    assert_equal [[:before_detach, "avatar", "funky.jpg"], [:after_detach, "avatar", "funky.jpg"]], Member.events
  end

  test "detaching a has_many_attached runs the detach callbacks for each file" do
    @member.photos.attach(create_blob(filename: "funky.jpg"), create_blob(filename: "town.jpg"))
    Member.events.clear

    @member.photos.detach

    assert_equal [
      [:before_detach, "photos", "funky.jpg"],
      [:before_detach, "photos", "town.jpg"],
      [:after_detach, "photos", "funky.jpg"],
      [:after_detach, "photos", "town.jpg"]
    ], Member.events
    assert_not @member.photos.attached?
    assert_not @member.reload.photos.attached?
  end

  test "purging a has_many_attached runs the detach callbacks for each file" do
    @member.photos.attach(create_blob(filename: "funky.jpg"), create_blob(filename: "town.jpg"))
    Member.events.clear

    @member.photos.purge

    assert_equal [
      [:before_detach, "photos", "funky.jpg"],
      [:after_detach, "photos", "funky.jpg"],
      [:before_detach, "photos", "town.jpg"],
      [:after_detach, "photos", "town.jpg"]
    ], Member.events
  end

  test "purging a has_many_attached later runs the detach callbacks for each file" do
    @member.photos.attach(create_blob(filename: "funky.jpg"), create_blob(filename: "town.jpg"))
    Member.events.clear

    @member.photos.purge_later

    assert_equal [
      [:before_detach, "photos", "funky.jpg"],
      [:after_detach, "photos", "funky.jpg"],
      [:before_detach, "photos", "town.jpg"],
      [:after_detach, "photos", "town.jpg"]
    ], Member.events
  end

  test "replacing the files of a has_many_attached runs the detach callbacks for each removed file" do
    @member.photos.attach(create_blob(filename: "funky.jpg"), create_blob(filename: "town.jpg"))
    Member.events.clear

    @member.update!(photos: [])

    assert_equal [
      [:before_detach, "photos", "funky.jpg"],
      [:before_detach, "photos", "town.jpg"],
      [:after_detach, "photos", "funky.jpg"],
      [:after_detach, "photos", "town.jpg"]
    ], Member.events
  end

  test "destroying the record runs the detach callbacks for each of its files" do
    @member.avatar.attach(create_blob(filename: "funky.jpg"))
    @member.photos.attach(create_blob(filename: "town.jpg"))
    Member.events.clear

    @member.destroy!

    assert_equal [
      [:before_detach, "avatar", "funky.jpg"],
      [:before_detach, "photos", "town.jpg"],
      [:after_detach, "avatar", "funky.jpg"],
      [:after_detach, "photos", "town.jpg"]
    ], Member.events
  end

  test "after_detach runs once the surrounding transaction commits" do
    @member.avatar.attach(create_blob(filename: "funky.jpg"))
    Member.events.clear

    Member.transaction do
      @member.avatar.detach
      assert_equal [[:before_detach, "avatar", "funky.jpg"]], Member.events
    end

    assert_equal [[:before_detach, "avatar", "funky.jpg"], [:after_detach, "avatar", "funky.jpg"]], Member.events
  end

  test "after_detach does not run when the detachment is rolled back" do
    @member.avatar.attach(create_blob(filename: "funky.jpg"))
    Member.events.clear

    Member.transaction do
      @member.avatar.detach
      raise ActiveRecord::Rollback
    end

    assert_equal [[:before_detach, "avatar", "funky.jpg"]], Member.events
    assert @member.reload.avatar.attached?
  end

  test "an exception from before_detach keeps the attachment" do
    @member.license.attach(create_blob(filename: "license.pdf"))

    assert_raises(ArgumentError, match: "kept") { @member.license.purge }
    assert_raises(ArgumentError, match: "kept") { @member.license.detach }
    assert_raises(ArgumentError, match: "kept") { @member.update!(license: nil) }

    assert @member.reload.license.attached?
  end

  test "detach callbacks do not run again for an attachment that was already removed" do
    @member.avatar.attach(create_blob(filename: "funky.jpg"))
    attachment = @member.avatar_attachment
    Member.events.clear

    attachment.purge
    attachment.purge
    @member.avatar.detach

    assert_equal [[:before_detach, "avatar", "funky.jpg"], [:after_detach, "avatar", "funky.jpg"]], Member.events
  end

  test "detach callbacks do not run for attachments that were never saved" do
    @member.photos_attachments.build(name: "photos", blob: create_blob(filename: "funky.jpg"))

    @member.photos.detach

    assert_empty Member.events
  end

  test "rolling back from before_detach keeps the attachment and its blob" do
    @member.draft.attach(create_blob(filename: "draft.txt"))
    blob = @member.draft.blob

    @member.draft.purge

    assert_empty Member.events
    assert @member.reload.draft.attached?
    assert ActiveStorage::Blob.exists?(blob.id)
  end

  test "purging runs after_detach once the blob has been purged" do
    @member.certificate.attach(create_blob(filename: "certificate.pdf"))
    blob = @member.certificate.blob

    assert_raises(ArgumentError, match: "too late") { @member.certificate.purge }

    assert_not ActiveStorage::Blob.exists?(blob.id)
  end

  test "destroying an attachment runs after_detach once the dependent blob has been purged" do
    @member.certificate.attach(create_blob(filename: "certificate.pdf"))
    blob = @member.certificate.blob

    assert_raises(ArgumentError, match: "too late") { @member.certificate_attachment.destroy }

    assert_not ActiveStorage::Blob.exists?(blob.id)
  end

  test "detaching an attachment without detach callbacks deletes it in a single query" do
    user = User.create!(name: "Jason", avatar: create_blob(filename: "funky.jpg"))

    assert_queries_count(1) { user.avatar.detach }
  end

  test "subclasses run the callbacks declared on their parent" do
    special_member = SpecialMember.create!(name: "Jason")

    special_member.avatar.attach(create_blob(filename: "funky.jpg"))
    special_member.avatar.purge

    assert_equal [
      [:before_attach, "avatar", "funky.jpg"],
      [:after_attach, "avatar", "funky.jpg"],
      [:before_detach, "avatar", "funky.jpg"],
      [:after_detach, "avatar", "funky.jpg"]
    ], Member.events
  end
end
