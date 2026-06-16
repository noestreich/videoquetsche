# Videoquetsche

Eine schlanke macOS-App zum Komprimieren von Videos per Drag & Drop — powered by ffmpeg.

## Features

- **Drag & Drop** — Videos einfach ins Fenster ziehen (MP4, MOV, AVI, MKV, WebM, M4V, FLV, WMV, MPG, 3GP)
- **Qualität per Slider** — CRF 18–35 (Hohe Qualität bis Sehr klein)
- **Auflösung wählen** — Original, 1080p, 720p oder 480p
- **Quadratisches Format** — Padding mit schwarzem oder weißem Hintergrund
- **Tonspur entfernen** — optional per Toggle
- **Fortschrittsanzeige** — Echtzeit-Progress pro Datei
- **Batch-Verarbeitung** — mehrere Videos nacheinander
- Output-Dateien landen neben dem Original als `*-small.mp4`

## Voraussetzungen

ffmpeg muss installiert sein:

```bash
brew install ffmpeg
```

Die App sucht ffmpeg automatisch unter `/opt/homebrew/bin/ffmpeg`, `/usr/local/bin/ffmpeg` und `/usr/bin/ffmpeg` und zeigt den Status direkt in der UI an.

## Build

In Xcode öffnen und bauen:

```bash
open VideoCompressor.xcodeproj
```

Oder per Skript:

```bash
./build.sh
```

## Lizenz

MIT
