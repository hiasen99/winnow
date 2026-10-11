# Winnow

<img src="Resources/icon.iconset/icon_256x256.png" width="128" align="right" alt="Winnow icon">

A Mac app for pulling short clips out of long multi-camera recordings — podcasts,
interviews, sermons, panel conversations. Think of a small Final Cut with Claude built in.

- **Drop in your files.** Up to four camera angles plus up to four separate audio
  recordings (lav mics, a recorder, a call platform's combined track). Winnow lines them
  all up by their sound.
- **Transcribed on your Mac.** Uses Apple's on-device speech recognition and works out
  who's talking. Nothing is uploaded.
- **Claude finds the clips.** Press *Find Clips* and Claude reads the transcript and
  suggests standalone moments. Use your own Claude API key, or copy the prompt into a
  Claude chat and paste the answer back — no key needed.
- **Edit on a real timeline.** Final Cut-style timeline with trimming, blade, markers,
  snapping and skimming. Cameras switch automatically to whoever is speaking, with
  manual overrides per section. Pick which mics you hear, per clip.
- **Captions that are easy to fix.** Captions are blocks on the timeline: drag to move,
  drag edges to re-time, double-click to fix the text. Style presets for the look.
- **Review fast.** Mark clips Used (U) or Rejected (X) and jump to the next.
- **Export** vertical, square or wide video with burned-in captions, audio only, or
  an .srt file.

## Download

[**Download Winnow.dmg**](https://github.com/hiasen99/winnow/releases/latest/download/Winnow.dmg)
— signed and notarized. Needs a Mac with Apple silicon (M1 or later) on **macOS 26** or later.

Open the disk image and drag Winnow to Applications.

## Claude

- **Find Clips** sends only the transcript text, and only when you press the button.
  Add an API key from [console.anthropic.com](https://console.anthropic.com) in
  Winnow → Settings. It's stored only on your Mac.
- **Claude desktop can work in Winnow directly** through MCP: read projects and
  transcripts, make and trim clips, fix captions and export. Add this to Claude's MCP
  settings and restart Claude:

  ```json
  { "mcpServers": { "winnow": {
      "command": "/Applications/Winnow.app/Contents/MacOS/Clips2", "args": ["--mcp"] } } }
  ```

## Build from source

Needs Xcode 26 (or its command line tools) on an Apple-silicon Mac running macOS 26.

```sh
./build.sh            # makes Winnow.app (ad-hoc signed)
./make-dmg.sh         # optional: packs it into Winnow.dmg
```

Set `SIGN_ID` (a Developer ID Application identity) and `NOTARY_PROFILE` (a
`notarytool` keychain profile) to make a signed, notarized build for sharing.

Internally the program is still called `Clips2` (bundle id `com.samuelroys.clips2`), and
its data lives in `~/Library/Application Support/Clips 2/`.

## License

MIT — see [LICENSE](LICENSE).
