# frozen_string_literal: true

module Telegram
  module WorkBot
    module Commands
      # BOTTLENECK — «разрыв момента». Покупатель стоит в квартире и называет цифру;
      # агент жмёт /bargain и набирает руководителя. За секунду до звонка у
      # руководителя в DM уже карточка: цена объекта, названная цена, сегмент,
      # сколько было показов и что не нравилось. Торг остаётся у руководителя —
      # но подготовленного. Реактивное сообщение: quiet hours не применяются.
      class Bargain < Base
        def handle
          # BOTTLENECK — порядок важен. resolve_lead! выкусывает из @args первое
          # положительное целое как номер лида, поэтому «/bargain 5200000» ответом
          # на карточку читался как лид #5200000 и агент получал «Лид не найден»
          # ровно в тот момент, ради которого команда и сделана — покупатель стоит
          # в квартире (найдено ревью PR #67). Если это reply, лид берём из него, а
          # аргументы целиком отдаём под цену.
          # В reply аргументы не трогаем вообще; в личке resolve_lead! выкусывает
          # номер лида, и под цену остаётся хвост.
          lead, price_args = if message['reply_to_message'].present?
                               [find_lead_via_reply, @args.to_s]
                             else
                               [resolve_lead!, nil]
                             end
          price_args ||= @args.to_s
          return reply(lead_not_found_hint('bargain 5,2 млн')) unless lead

          price = Formatters::PriceParse.call(price_args)
          if price.nil?
            return reply('Формат: <code>/bargain 5,2 млн</code> (reply на карточку) или ' \
                         '<code>/bargain &lt;lead_id&gt; 5200000</code> в личке.')
          end

          record!(lead, price)
          delivered = notify_directors(lead, price)
          return reply('⚠️ Ни один руководитель не получил DM — звони напрямую.') if delivered.zero?

          reply("📞 Руководитель предупреждён (#{delivered}) — звони и передавай трубку.")
        end

        private

        def record!(lead, price)
          history = lead.append_history(key: 'bargain_requests',
                                        entry: { 'at' => Time.current.iso8601, 'price' => price.to_i, 'by' => tg_user.mention })
          lead.update!(metadata: lead.metadata.merge('bargain_requests' => history))
        end

        def notify_directors(lead, price)
          text = card(lead, price)
          delivered = 0
          Telegram::CriticalRecipients.resolve.each do |recipient|
            chat_id = recipient.dm_chat_id || recipient.tg_user_id
            next if chat_id.blank?

            client.send_message(text, chat_id: chat_id, parse_mode: 'HTML')
            delivered += 1
          rescue Telegram::Client::Error => e
            Rails.logger.warn("[Commands::Bargain] DM to #{recipient.mention} failed: #{e.message}")
          end
          delivered
        end

        def card(lead, price)
          property = lead.property
          summary = property ? Kpi::ShowFunnel.objections_summary(property: property) : { shows: 0, objections: [] }
          objections = summary[:objections].first(4).map { |t, n| "#{n}× #{escape_html(t)}" }.join(', ')
          lines = ["🔥 <b>Торг на объекте</b> — #{escape_html(tg_user.display_name)} сейчас с покупателем"]
          lines << "Объект: #{escape_html(property&.address.presence || "лид ##{lead.id}")}"
          lines << "Цена: <b>#{property&.price_formatted || '—'}</b> · предлагают: <b>#{delimited(price)} ₽</b>"
          lines << "Покупатель: #{escape_html(lead.metadata['name'].presence || '—')} · #{lead.segment_label}"
          lines << "Показов: #{summary[:shows]} #{plural(summary[:shows])}#{objections.present? ? " · #{objections}" : ''}"
          lines << lead.anchor_url if lead.anchor_url
          lines.join("\n")
        end

        def delimited(price)
          ActiveSupport::NumberHelper.number_to_delimited(price.to_i, delimiter: ' ')
        end

        def plural(n)
          return 'показов' if (11..14).cover?(n % 100)
          return 'показ' if n % 10 == 1
          return 'показа' if (2..4).cover?(n % 10)

          'показов'
        end
      end
    end
  end
end
