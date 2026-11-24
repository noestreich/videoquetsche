## Was ist neu

- **Videos per Link laden**: Web-Links zu MP4-Videos, HLS-Streams (`.m3u8`) oder m3u-Playlisten ins neue Textfeld einfügen. Die Videos werden mit yt-dlp nach `~/Downloads/Videoquetsche` geladen und landen danach in der Warteschlange. Playlisten werden in einzelne Einträge aufgeteilt.
- **Unscharfer Hintergrund**: Beim quadratischen Format gibt es neben Schwarz und Weiß jetzt „Unscharf“, also das eigene Video weichgezeichnet als Hintergrund.
- **Bug-Fix**: Wenn ein Video auf das Dock-Icon gezogen wurde, öffnete sich ein zweites Fenster und der Eintrag erschien mehrfach. Das passiert nicht mehr.
- Dateien, die während der Verarbeitung hinzukommen (auch fertige Downloads), werden im selben Durchlauf mit komprimiert.
- Universal-Build (Apple Silicon und Intel), signiert und von Apple notarisiert.

## Installation

1. ZIP entpacken
2. `Videoquetsche.app` in den Programme-Ordner ziehen

**Voraussetzungen:** ffmpeg (`brew install ffmpeg`), für Links zusätzlich yt-dlp (`brew install yt-dlp`)
