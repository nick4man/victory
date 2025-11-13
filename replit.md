# АН "Виктори" - Real Estate Agency Platform

## Overview
Ruby on Rails 7.1 real estate platform for АН "Виктори" (Viktory Realty Agency). The project was imported from GitHub and redesigned with a clean, minimalist aesthetic inspired by the Sminex reference website.

## Current State
- **Status**: Landing page redesigned with Sminex-inspired minimalist design ✅
- **Environment**: Replit (NixOS) with Ruby 3.2.2, PostgreSQL
- **Server**: Running on port 5000 (Rails/Puma)
- **Design**: Clean, minimalist white aesthetic with large typography

## Recent Changes (November 13, 2024)

### Design Redesign
- Completely redesigned landing page to match Sminex reference website
- Implemented minimalist white aesthetic with bold typography
- Large hero section with "ПРОФЕССИОНАЛЫ ЭЛИТНОЙ НЕДВИЖИМОСТИ" heading
- Clean navigation and lots of whitespace
- Removed colorful gradients in favor of black-on-white design
- Added stats section, values section, and comprehensive footer

### Technical Setup
- Created standalone `LandingController` to avoid gem dependencies
- Bypassed removed gems (ActiveAdmin, Devise, Pundit, Sidekiq, etc.)
- Database created and migrations run successfully
- Configured for Replit environment (port 5000, 0.0.0.0 binding, allow all hosts)

## Project Architecture

### Controllers
- `LandingController`: Standalone landing page (no layout, no gem dependencies)
- `HomeController`: Original homepage (disabled, gem-dependent)
- `ApplicationController`: Has stub methods for removed Devise functionality

### Routes
- Root: `landing#index` (minimalist landing page)
- Original routes temporarily disabled due to missing gems

### Dependencies
- Simplified Gemfile with problematic gems removed
- Uses Tailwind CSS via CDN for styling
- Inter font from Google Fonts

## Disabled Features (Due to Compilation Issues)
- ActiveAdmin (admin panel)
- Devise (authentication)
- Sidekiq (background jobs)
- Rack::Attack (rate limiting)
- Carrierwave (file uploads)
- Pundit (authorization)
- Meta-tags gem
- Letter Opener Web

## Design Inspiration
Website design based on Sminex (https://sminex.com):
- Clean, minimalist aesthetic
- Large hero sections with bold typography
- Emphasis on whitespace and elegant presentation
- Black text on white background
- Simple, professional navigation
- Focus on content over decoration

## Next Steps
1. Re-add essential features with proper gem installation
2. Consider implementing production-ready Tailwind CSS
3. Add real property data from database
4. Implement search functionality
5. Add authentication if needed

## Development Notes
- Port 5000 is required for frontend (Replit proxy)
- Server bound to 0.0.0.0 for Replit compatibility
- Development environment allows all hosts for proxy system
- Landing page renders without application layout to avoid gem dependencies
