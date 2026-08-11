# frozen_string_literal: true

module Admin
  # Приём файла из блок-редактора (app/views/admin/shared/_block_editor).
  # Редактор шлёт FormData с единственным ключом `file` и ждёт обратно
  # signed_id, который кладёт в блок; сам блоб к записи не привязывается —
  # LandingBlocksHelper резолвит его при рендере по signed_id.
  #
  # Общий для всех админ-ресурсов с `body_blocks`. Каждый заводит свой
  # collection-роут `post :upload_image` и передаёт его в партиал через
  # local `upload_url`: переиспользовать чужой роут значило бы сцепить
  # несвязанные ресурсы.
  module UploadsBlockImages
    extend ActiveSupport::Concern

    def upload_image
      blob = ActiveStorage::Blob.create_and_upload!(
        io: params.require(:file),
        filename: params[:file].original_filename,
        content_type: params[:file].content_type
      )
      render json: {
        signed_id: blob.signed_id,
        filename:  blob.filename.to_s,
        url:       url_for(blob)
      }
    rescue StandardError => e
      # self.class.name, а не хардкод ресурса: строка лога должна называть
      # того, кто реально обрабатывал запрос.
      Rails.logger.warn("[#{self.class.name}#upload_image] #{e.class}: #{e.message}")
      render json: { error: e.message }, status: :unprocessable_entity
    end
  end
end
