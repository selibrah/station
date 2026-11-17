#!/usr/bin/env bash
# start_gemini_station.sh — station with the Gemini preset (gemini.google.com + saved Gemini profile).
exec "$(dirname "${BASH_SOURCE[0]}")/start_station.sh" --gemini "$@"
