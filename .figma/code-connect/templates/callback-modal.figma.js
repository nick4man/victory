// Code Connect mapping: Figma "Callback Modal" → existing shared partial.
//
// Partial source: app/views/shared/_callback_modal.html.erb
// Trigger Stimulus controller: app/javascript/controllers/app_controller.js
// (data-action="click->app#openModal" data-modal-target="callback")

import figma from '@figma/code-connect';

figma.connect(
  'https://www.figma.com/design/<FILE_KEY>/<FILE_NAME>?node-id=<CALLBACK_MODAL_NODE>',
  {
    example: () => `
<%# Place once per page (typically in layout or hero section). The modal
    is hidden by default and toggled by any element with
    data-action="click->app#openModal" data-modal-target="callback". %>
<%= render 'shared/callback_modal' %>
`,
  }
);
