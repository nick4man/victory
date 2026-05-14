// Code Connect mapping: Figma "Button" component → ERB + Tailwind snippet.
//
// To wire to a specific Figma node:
//   1. In Figma: open the design file, copy the URL of the Button frame
//   2. Replace `figmaNode` below with that URL
//   3. Run `npm run figma:publish` to push mappings to Figma
//
// Once published, the Figma MCP server will return this ERB snippet
// when an agent asks `figma:figma-implement-design <button-url>` instead
// of generating React. See .claude/skills/figma-to-erb-handoff for the
// full workflow.

import figma from '@figma/code-connect';

figma.connect(
  'https://www.figma.com/design/<FILE_KEY>/<FILE_NAME>?node-id=<NODE_ID>',
  {
    props: {
      label:   figma.string('label'),
      variant: figma.enum('variant', { primary: 'btn-primary', secondary: 'btn-secondary', ghost: 'btn-ghost' }),
      size:    figma.enum('size',    { sm: 'px-3 py-1.5 text-sm', md: 'px-4 py-2', lg: 'px-6 py-3 text-lg' }),
      icon:    figma.boolean('hasIcon'),
    },
    example: ({ label, variant, size }) => `
<%= link_to '#', class: '${variant} ${size} inline-flex items-center justify-center rounded-lg font-medium transition-colors' do %>
  ${label || 'Кнопка'}
<% end %>
`,
  }
);
