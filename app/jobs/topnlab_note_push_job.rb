# frozen_string_literal: true

class TopnlabNotePushJob < ApplicationJob
  queue_as :default

  def perform(note_id)
    note = Note.find_by(id: note_id)
    return Rails.logger.info("[TopnlabNotePushJob] note ##{note_id} not found") unless note
    return if note.synced?

    Topnlab::NotesSyncService.new.push(note)
  end
end
