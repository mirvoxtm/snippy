# snippy

snippy is the screenshot and screen recording tool of [milk](https://github.com/mirvoxtm/milk). it's inspired by the windows 11 screenshot tool.

under milk it wears milk's colours, fonts and icons (from `milk.json`). under any other X11 window manager it uses milk's default look.

Keep the snippy folder next to your milk folder, then:

```sh
cd snippy
./build.sh
./snippy          # rebuilds by itself when its sources (or milk's) change
```

milk's Super+Shift+S (`contrib/milk-screenshot`) uses snippy when it is next to milk or on the `PATH`.

## Using it

- **the bar**: photo or video, then rectangle (R), window (W), full screen (S) and free form (F).
  For videos, the resolution; for photos, the pen opens the editor after each capture. Escape or
  a right click closes it.
- **window list**: point at the Window button and a side bar lists the open windows, with a
  small picture, the icon and the title. Pointing at one lights it up; clicking it takes it.
- **after a capture**: the picture is on the clipboard (image/png) and saved in
  `Pictures/Screenshots`. The notification's *Edit* opens it in the editor.
- **the editor**: pen and highlighter (each with its colour), eraser, crop, undo and redo. Edits
  reach the clipboard by themselves; Ctrl+S saves, Ctrl+C copies, Ctrl+N takes a new one.
- **videos**: choose the region (16:9 when a resolution is set), then *Record*: a red frame marks
  the region, a 3-2-1 countdown, and the bar shows the time with Stop and Discard. The microphone
  and the system sound are toggles on that bar. The video is H.264 in MP4, at the chosen size
  (4K, 1440p, 1080p, 720p, 480p or the region's own), saved in `Videos/Screen Recordings`; its
  file goes to the clipboard, so it pastes into file managers and chats.

```
snippy [snip] [options]     the bar over the frozen screen
snippy record [options]     choose a region and record it
snippy stop                 stop the recording (snip or record while recording do the same)
snippy window               the window: New, mode, delay, video resolution and frame rate
snippy open FILE            a picture in the editor

  -m, --mode rect|window|screen|free    -d, --delay SECONDS     --no-save
  -r, --resolution 4k|1440|1080|720|480|original                --fps 30|60
```

The choices are remembered in `~/.config/snippy/snippy.json` (`autosave` turns the
Screenshots copy off).

## needs

to build: Odin and milk's sources (`../milk/src`, `$MILK_SRC`, or the milk recorded in `~/.config/milk/location`).

to run: libX11, libXft, fontconfig, libXrandr, libXext, zlib and
libdbus (notifications; snippy works without a notification server). 

recording needs ffmpeg with x11grab (and PulseAudio or PipeWire for sound); without it, only recording is missing.