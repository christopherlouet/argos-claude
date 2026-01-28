# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.1] - 2026-01-28

### Fixed
- Remove Pango markup from dropdown menu to prevent intermittent blank menu on refresh (GNOME Shell 49 race condition)

## [1.0.0] - 2025-01-27

### Added
- Initial release of Claude Code Usage Argos plugin
- Display weekly tokens, active model, and estimated cost savings in GNOME panel
- Dropdown menu with detailed statistics:
  - Today's tokens (when available)
  - Weekly tokens with sparkline visualization
  - Total tokens with days since first session
  - Cost savings breakdown (week, month, total)
  - Current project name
- Quick actions: View usage on claude.ai, Refresh
- Support for Opus and Sonnet models pricing
- Subscription type display (Pro, Max)
- Active Claude sessions counter

### Fixed
- Robust error handling to prevent menu freeze on jq/bc errors
- Fallback values for all JSON parsing operations
- Input validation in formatting functions
