// Code Connect mapping: Figma "News Carousel" → shared partial.
//
// Partial: app/views/shared/_news_carousel.html.erb
// Custom JS (touch-swipe, arrows, dots) inlined within the partial —
// not via Stimulus (predates the controller pattern; refactor candidate).

import figma from '@figma/code-connect';

figma.connect(
  'https://www.figma.com/design/<FILE_KEY>/<FILE_NAME>?node-id=<NEWS_CAROUSEL_NODE>',
  {
    props: {
      limit: figma.number('limit'),
    },
    example: ({ limit }) => `
<%# Recent published articles (defaults to limit=8). The partial owns
    its data fetch — pulls Article.public_facing.limit(N) internally. %>
<%= render 'shared/news_carousel', limit: ${limit || 8} %>
`,
  }
);
