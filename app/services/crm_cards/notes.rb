# frozen_string_literal: true

module CrmCards
  # Заметки по карточке: сотрудник дописывает, как идёт работа с клиентом —
  # созвонились, о чём договорились, что дальше. Модерации здесь нет и быть не
  # должно: это ход работы, а не данные клиента. Чувствительные поля (имя,
  # телефон) правятся отдельным путём и с модерацией.
  #
  # Заметка только добавляется. Прежние записи не переписываются: история
  # разговоров с клиентом — это то, ради чего карточку и ведут.
  #
  # Карточка уже в CRM — заметка уходит туда же (Topnlab set-note), чтобы
  # коллега, открывший заявку в CRM, видел тот же ход работы, а риелтору не
  # приходилось писать одно и то же дважды.
  class Notes
    MIN = 3
    MAX = 2000

    # Тип сущности в CRM: заявка из карточки лида — order, объект — realty.
    CRM_TYPES = { 'lead' => 'order', 'object' => 'realty' }.freeze

    Result = Struct.new(:ok, :note, :error, keyword_init: true) do
      def ok? = ok == true
    end

    def self.add!(card, actor:, text:) = new(card, actor: actor, text: text).add!

    def initialize(card, actor:, text:)
      @card = card
      @actor = actor
      @text = text.to_s.strip
    end

    def add!
      return deny(denial) if denial

      note = Note.create!(notable: @card, user: crm_user, note: @text,
                          crm_user_id: crm_user&.crm_user_id,
                          crm_entity_type: CRM_TYPES[@card.kind])
      # В CRM — только когда там уже есть к чему прикрепить.
      TopnlabNotePushJob.perform_later(note.id) if @card.crm_id.present? && !@card.sandbox?
      Result.new(ok: true, note: note)
    end

    private

    def deny(error) = Result.new(ok: false, error: error)

    def denial
      perms = Permissions.for(@actor)
      return perms.denial if perms.denial
      return 'Заметку по карточке пишет тот, кто ведёт клиента.' unless participant?(perms)
      return "Слишком коротко: нужно от #{MIN} символов." if @text.length < MIN
      return "Слишком длинно: #{@text.length} симв., влезает #{MAX}." if @text.length > MAX

      nil
    end

    # Тот, кто ведёт клиента сейчас, и модератор. Прежний автор, у которого
    # лид забрали, дописывать не может — как не может и править карточку.
    def participant?(perms)
      @card.responsible&.id == @actor.id || perms.can?(:moderate)
    end

    def crm_user
      return @crm_user if defined?(@crm_user)

      @crm_user = ::User.find_by(telegram_user_id: @actor.id)
    end
  end
end
