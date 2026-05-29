# frozen_string_literal: true

module Dashboard
  module Admin
    # A6 Phase 2 — Admin review UI для ClientDocument intake.
    # Workflow:
    #   /admin/client_documents       → очередь pending review (ocr_completed)
    #   /admin/client_documents/:id   → show с masked parsed_data + verify form
    #   PATCH approve                  → status=reviewed + reviewed_at + reviewed_by_user_id
    #   PATCH reject                   → status=ocr_failed + error_message
    #
    # Authorization: require_admin! (token via Dashboard::BaseController).
    # DLP: показываем parsed_data_masked в index, full parsed_data в show
    # (только для admin user).
    class ClientDocumentsController < Dashboard::BaseController
      before_action :require_admin!
      before_action :set_document, only: [:show, :approve, :reject]

      def index
        @status = params[:status].presence_in(['pending', 'all', 'failed', 'reviewed']) || 'pending'
        @documents = filtered_scope.includes(:uploader, :property, :inquiry)
                                   .order(created_at: :desc).limit(50)
        @counts = {
          pending: ClientDocument.pending_review.count,
          failed: ClientDocument.where(status: :ocr_failed).count,
          reviewed: ClientDocument.where(status: :reviewed).count,
          all: ClientDocument.count
        }
      end

      def show
        # Phase 9 Iter 2 — DLP: по умолчанию admin видит MASKED данные.
        # Полный unmasked доступен через `?reveal=1` (audit-logged для compliance).
        @masked_data = @document.parsed_data_masked
        @reveal      = params[:reveal] == '1'
        @parsed_data = @reveal ? @document.parsed_data : @masked_data

        if @reveal
          Rails.logger.info("[Admin DLP reveal] document_id=#{@document.id} kind=#{@document.document_kind} " \
                            "by_token=#{request.params[:token].to_s[0, 8]}*** at=#{Time.current.iso8601}")
        end
      end

      def approve
        admin_user = current_user || User.find_by(role: 'admin')
        @document.update!(
          status: :reviewed,
          reviewed_at: Time.current,
          reviewed_by_user_id: admin_user&.id
        )

        # Re-mirror в NC с новым reviewed_by — теперь DocumentUpload запись создаётся
        DocumentIntake::NextcloudMirror.call(client_document: @document)

        redirect_to dashboard_admin_client_documents_path,
                    notice: "Документ #{@document.document_kind} подтверждён."
      end

      def reject
        @document.update!(
          status: :ocr_failed,
          error_message: params[:reason].presence || 'Manual rejection by admin'
        )
        redirect_to dashboard_admin_client_documents_path,
                    notice: 'Документ помечен на повторную обработку.'
      end

      private

      def set_document
        @document = ClientDocument.find(params[:id])
      end

      def filtered_scope
        case @status
        when 'pending'  then ClientDocument.pending_review
        when 'failed'   then ClientDocument.where(status: :ocr_failed)
        when 'reviewed' then ClientDocument.where(status: :reviewed)
        else                 ClientDocument.all
        end
      end
    end
  end
end
