#!/bin/zsh
# Version from the date: 1.year.week (build: day.hour). Apple allows at most three numbers in each.
set -e
cd "${0:a:h}"
version="1.$(date +%g.%V)"
build="$(date +%u.%H)"
sed -i '' -E "s/MARKETING_VERSION = [^;]+;/MARKETING_VERSION = $version;/; s/CURRENT_PROJECT_VERSION = [^;]+;/CURRENT_PROJECT_VERSION = $build;/" VoiceAgent.xcodeproj/project.pbxproj
echo "$version ($build)"
