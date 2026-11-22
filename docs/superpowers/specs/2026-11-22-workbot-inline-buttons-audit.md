# Аудит inline-кнопок рабочего Telegram-бота (Telegram::WorkBot)

Дата аудита: 22.11.26. Ветка: `kanban/tg-inline-buttons-audit` → PR в `dev/chat`.

Реестр «кнопка → обработчик → статус». Проверка обработчика: живая ветка в
`CallbacksRouter::PREFIX_MAP` / `Wizard::Engine::FLOWS` плюс корректный разбор
действий внутри callback-класса. Сверка с боем: `bot_command_logs` за
последний месяц (нажатий с результатом `unknown_command` не зафиксировано ни
одного).

## Сводка

| Префикс callback_data | Где строится кнопка | Обработчик | Статус |
|---|---|---|---|
| `route` | `LeadAnnouncer` | `Callbacks::RouteCallback` | рабочий |
| `assign` | `LeadAnnouncer` | `Callbacks::AssignCallback` | рабочий |
| `assign_to` | `Commands::Assign`, `AssignCallback` | `Callbacks::AssignToCallback` | рабочий |
| `assign_cancel` | `AssignCallback` | `Callbacks::AssignCancelCallback` | рабочий |
| `spam` | `LeadAnnouncer` | `Callbacks::SpamCallback` | рабочий |
| `stage` | `LeadAnnouncer` | `Callbacks::StageCallback` | рабочий |
| `segment` | `SegmentKeyboard` (3 места) | `Callbacks::SegmentCallback` | рабочий |
| `show_assign` | `ShowRouting` (тёмный код, `SHOW_ROUTING_ENABLED`) | `Callbacks::ShowAssignCallback` | рабочий |
| `show_report` | `ShowReports::Confirmer`, `ShowReports::Finalizer` | `Callbacks::ShowReportCallback` | рабочий |
| `wiz:s:task` / `wiz:s:close` / `wiz:s:reopen` | `LeadAnnouncer`, `Wizard::Menu`, `ReopenFlow` | `Wizard::Engine` (`TaskFlow` / `CloseFlow` / `ReopenFlow`) | рабочие |
| `wiz:s:crm_lead` | `LeadAnnouncer`, `LeadAssignment`, `Menu`, `CrmTestLeadFlow` | `Wizard::CrmLeadCardFlow` | рабочий |
| `wiz:s:crm_test_lead` | `Menu` (только в test-боте) | `Wizard::CrmTestLeadFlow` | рабочий |
| `wiz:s:crm_object` | `Menu` | `Wizard::CrmObjectCardFlow` | рабочий |
| `wiz:s:crm_edit` / `crm_rework` / `crm_approve` / `crm_release` / `crm_note` / `crm_change` / `crm_manual` | `CrmCards::CardView`, `Menu` | соответствующие `Wizard::Crm*Flow` | рабочие |
| `wiz:p/m/b/x/menu` | `Wizard::Engine` | `Callbacks::WizardCallback` | рабочие |
| `task:<id>:start\|done` | `TaskDispatcher`, `TaskFlow`, `ReopenFlow` | `Callbacks::TaskActionCallback` | рабочий |
| `batch_confirm` | `TaskBatchConfirmer`, `VoiceIntakeProcessor` | `Callbacks::TaskBatchConfirmCallback` | рабочий |
| `photo:dispose/target/lead/staff/share_to` | `PhotoIntakeProcessor`, `PhotoDispositionCallback` | `Callbacks::PhotoDispositionCallback` | рабочие |
| `dashboard:drill/refresh/back` | `DirectorDashboard`, дайджесты | `Callbacks::DashboardDrillCallback` | рабочий |
| `link_staff:list/tg/do/report` | `Commands::Link`, `LinkStaffCallback` | `Callbacks::LinkStaffCallback` | рабочий |
| `owner:contact/cancel/snooze/decline/invite` | `OwnerRequestJob`, `OwnerIntakeProcessor`, `OwnerRequestCallback` | `Callbacks::OwnerRequestCallback` | рабочий |
| `tutorial:go/finish` | `TutorialRenderer` | `Callbacks::TutorialCallback` | рабочий |
| `crm_card:view/submit/retry` | `CrmCards::CardView`, `Commands::Cards`, `LeadAnnouncer` | `Callbacks::CrmCardCallback` | рабочий |
| `wiz:s:crm_attach` | `CrmCards::CardView` (статусы `exporting`/`export_failed`) | **отсутствовал** | **мёртвая — починена в этом PR** |

## Найденное и исправленное

1. **`wiz:s:crm_attach:<id>` («📎 Номер из CRM» / «✅ Подтвердить номер из CRM»)** —
   кнопка рендерилась в `CrmCards::CardView` для модератора при зависшей или
   неоднозначно сбойной выгрузке заявки, но мастера `crm_attach` не было в
   `Wizard::Engine::FLOWS`: нажатие всегда получало алерт «Неизвестный мастер».
   Путь recovery при этом спроектирован и задокументирован (план
   `docs/superpowers/plans/2026-09-14-crm-card-moderation.md`, Task 11;
   `Workflow#attach_export_number!` написан и покрыт спеками), а дубль
   кнопки «Повторить выгрузку» для этих статусов запрещён (`export_retryable:
   false`). Удалять кнопку значило бы оставить сбойные заявки без
   восстановления — вместо удаления реализован мастер
   `Wizard::CrmCardAttachFlow` (спека —
   `spec/services/telegram/work_bot/wizard/crm_card_attach_flow_spec.rb`).
2. **`Callbacks::WipStub`** — заглушка Phase 2 (шаг 3) из комментария
   «реальные обработчики подменят эту мапу в шагах 4-9»: не referenced в
   `PREFIX_MAP` и нигде больше. Удалён вместе с устаревшим комментарием.
3. **`TaskBatchConfirmCallback#cancel!`** — dead-метод, оставленный «чтобы
   тесты не ломались» с пометкой «удалить в следующем рефакторинге»
   (Phase 10 Iter 13): отмена inlined в `handle`. Удалён; спека
   `task_batch_confirm_callback` отмену покрывает через настоящий путь
   `batch_confirm:<id>:cancel`.

## Кнопки, которые НЕ тронуты (осознанно)

- `show_assign` — тёмный код (`SHOW_ROUTING_ENABLED`), обработчик живой.
- `photo:dispose:staff` — legacy-алиас `task` для закэшированных кнопок
  (TTL pending_action 10 минут), оставлен для back-compat.
- `/menu`-ряд `wiz:s:crm_test_lead` — виден только в тест-боте
  (`Telegram::BotContext.test?`), гейты изоляции staff-test (#228) не менялись.

## Покрытие тестами

Каждая рабочая кнопка уже покрыта парой «рендер + обработчик»: клавиатуры —
`spec/services/crm_cards/card_view_spec.rb`,
`spec/services/telegram/work_bot/{lead_announcer_test_lead_spec.rb,
segment_keyboard_spec.rb, director_dashboard_spec.rb, daily_digest_job_spec.rb,
weekly_summary_job_spec.rb, show_routing_spec.rb, tutorial_renderer_spec.rb,
photo_intake_processor_spec.rb, owner_intake_processor_spec.rb}`,
`spec/services/telegram/work_bot/commands/*`; обработчики —
`spec/services/telegram/work_bot/callbacks/*`. Мастер `crm_attach` покрыт
новой спекой `crm_card_attach_flow_spec.rb` (кнопка → мастер → привязка,
отказы для не-модератора и не тех статусов, невалидный ввод).
