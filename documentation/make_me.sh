#!/usr/bin/env bash
set -e

# Run this from the BIKESv3 root folder

DOCS_ROOT="documentation/BIKES-docs"
DOCS_DIR="$DOCS_ROOT/docs"

echo "Building BIKES MKDocs structure..."

mkdir -p "$DOCS_DIR"

# ------------------------------------------------------------
# Main pages
# ------------------------------------------------------------

cat > "$DOCS_DIR/index.md" <<'EOF'
# BIKES Documentation

Welcome to the BIKES project documentation.

This site documents the structure, concepts, media, utility scripts, and technical systems used in the BIKES project.

## Main sections

- [Project Overview](project-overview.md)
- [Concepts](concepts/index.md)
- [Media](media/index.md)
- [Utility](utility/index.md)
EOF

cat > "$DOCS_DIR/project-overview.md" <<'EOF'
# Project Overview

BIKES is a networked sound art system using mobile bike-based sound nodes.

The project combines:

- Raspberry Pis
- SuperCollider
- Networked audio/control systems
- UWB distance sensing
- Speakers mounted on bikes
- Public space performance and installation practice

## Core idea

The physical arrangement of the bikes becomes part of the musical system.

As bikes move closer together or farther apart, their distances can affect timing, delay, pitch, density, sample playback, and musical interaction.
EOF

# ------------------------------------------------------------
# Concepts
# ------------------------------------------------------------

mkdir -p "$DOCS_DIR/concepts"

cat > "$DOCS_DIR/concepts/index.md" <<'EOF'
# Concepts

This section documents the major concept folders in the BIKES project.

Each concept folder represents a different technical or compositional experiment.
EOF

# Format:
# source_folder|DisplayTitle
CONCEPT_LIST="
forwarding|Forwarding
GranSynth|GranSynth
Latency_delay|LatencyDelay
soundscapes|Soundscapes
timesync|Timesync
uwb|Uwb
"

echo "$CONCEPT_LIST" | while IFS="|" read -r src_folder title; do
    # Skip empty lines
    if [ -z "$src_folder" ]; then
        continue
    fi

    target_folder="$DOCS_DIR/concepts/$title"

    mkdir -p "$target_folder"

    cat > "$target_folder/index.md" <<EOF
# $title

This page documents the \`concepts/$src_folder\` folder.

## Purpose

Describe what this concept does and how it connects to the larger BIKES system.

## Important files

EOF

    if [ -d "concepts/$src_folder" ]; then
        find "concepts/$src_folder" -maxdepth 1 -type f | sort | while read -r file; do
            base="$(basename "$file")"
            echo "- \`$base\`" >> "$target_folder/index.md"
        done
    else
        echo "_Source folder not found yet: \`concepts/$src_folder\`_" >> "$target_folder/index.md"
    fi

    cat >> "$target_folder/index.md" <<EOF

## Notes

Add setup instructions, code notes, performance behavior, and troubleshooting details here.
EOF
done

# ------------------------------------------------------------
# Media
# ------------------------------------------------------------

mkdir -p "$DOCS_DIR/media"

cat > "$DOCS_DIR/media/index.md" <<'EOF'
# Media

This section documents the `media/` folder.

The media folder contains sound files and other assets used by the BIKES system.

## Media folders

EOF

if [ -d "media" ]; then
    find media -maxdepth 1 -mindepth 1 -type d | sort | while read -r folder; do
        base="$(basename "$folder")"
        echo "- \`$base/\`" >> "$DOCS_DIR/media/index.md"
    done

    cat >> "$DOCS_DIR/media/index.md" <<'EOF'

## Notes

Document which sounds are used by which SuperCollider scripts.

For each media folder, note:

- What the sounds are
- Which script uses them
- Whether they need to exist on every bike
- Expected file format
- Any naming conventions
EOF
else
    echo "_No top-level media folder found._" >> "$DOCS_DIR/media/index.md"
fi

# ------------------------------------------------------------
# Utility
# ------------------------------------------------------------

mkdir -p "$DOCS_DIR/utility"

cat > "$DOCS_DIR/utility/index.md" <<'EOF'
# Utility

This section documents the `utility/` folder.

The utility folder contains helper scripts, setup scripts, deployment tools, and maintenance commands for the BIKES project.

## Utility files

EOF

if [ -d "utility" ]; then
    find utility -maxdepth 1 -type f | sort | while read -r file; do
        base="$(basename "$file")"
        echo "- \`$base\`" >> "$DOCS_DIR/utility/index.md"
    done

    cat >> "$DOCS_DIR/utility/index.md" <<'EOF'

## Notes

For each utility script, document:

- What it does
- Where it should be run from
- Whether it runs locally or on the Raspberry Pis
- Any required arguments
- Any dangerous commands it runs
EOF
else
    echo "_No top-level utility folder found._" >> "$DOCS_DIR/utility/index.md"
fi

# ------------------------------------------------------------
# mkdocs.yml
# ------------------------------------------------------------

cat > "$DOCS_ROOT/mkdocs.yml" <<'EOF'
site_name: BIKES Documentation
site_description: Documentation for the BIKES networked sound project
site_author: Orlando Kenny

theme:
  name: material
  features:
    - navigation.sections
    - navigation.expand
    - navigation.top
    - content.code.copy
  palette:
    - scheme: default
      primary: black
      accent: deep orange

nav:
  - Project Overview: project-overview.md
  - Concepts:
      - Overview: concepts/index.md
      - Forwarding: concepts/Forwarding/index.md
      - GranSynth: concepts/GranSynth/index.md
      - LatencyDelay: concepts/LatencyDelay/index.md
      - Soundscapes: concepts/Soundscapes/index.md
      - Timesync: concepts/Timesync/index.md
      - Uwb: concepts/Uwb/index.md
  - Media: media/index.md
  - Utility: utility/index.md

markdown_extensions:
  - admonition
  - toc:
      permalink: true
  - fenced_code
  - tables
  - attr_list
  - md_in_html
EOF

echo ""
echo "Done."
echo ""
echo "Run:"
echo "cd $DOCS_ROOT"
echo "mkdocs serve"