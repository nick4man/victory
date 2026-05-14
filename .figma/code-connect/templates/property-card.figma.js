// Code Connect mapping: Figma "Property Card" component → ERB partial call.
//
// The actual rendering lives in app/views/properties/_property_card.html.erb
// (or wherever the catalog card is defined). Code Connect returns the
// `<%= render %>` call rather than re-inlining markup — keeps both the
// Figma side and the codebase side aligned to a single source of truth.

import figma from '@figma/code-connect';

figma.connect(
  'https://www.figma.com/design/<FILE_KEY>/<FILE_NAME>?node-id=<PROPERTY_CARD_NODE>',
  {
    props: {
      featured: figma.boolean('isFeatured'),
      compact:  figma.boolean('isCompact'),
    },
    example: ({ featured, compact }) => `
<%= render 'properties/property_card',
           property: property,
           featured: ${featured ? 'true' : 'false'},
           compact:  ${compact ? 'true' : 'false'} %>
`,
  }
);
