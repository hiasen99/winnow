# Winnow

<img src="Resources/icon.iconset/icon_256x256.png" width="128" align="right" alt="Winnow icon">

A Mac app for pulling short clips out of long multi-camera recordings — podcasts,
interviews, sermons, panel conversations. Think of a small Final Cut with Claude built in.

- **Drop in your files.** Up to four camera angles plus up to four separate audio
  recordings (lav mics, a recorder, a call platform's combined track). Winnow lines them
  all up by their sound.
- **Transcribed on your Mac.** Uses Apple's on-device speech recognition and works out
  who's talking, then lines every word up with the moment it's spoken so captions land
  on time (English; a one-time 175 MB download). Nothing is uploaded.
- **Claude finds the clips.** Press *Find Clips* and Claude reads the transcript and
  suggests standalone moments. Use your own Claude API key, or copy the prompt into a
  Claude chat and paste the answer back — no key needed.
- **Edit on a real timeline.** Final Cut-style timeline with trimming, blade, markers,
  snapping and skimming. Cameras switch automatically to whoever is speaking. Select any
  stretch and pick a camera or the mics you hear for exactly that stretch, and use ↑ / ↓
  to jump from cut to cut.
- **Frame each camera, or each shot.** Move and zoom each camera's picture inside the
  vertical, square or wide frame, reframe a single shot when someone moves, and give each
  camera its own caption height so captions stay clear of faces and mics. Zoom out below
  1× (or press *Fit* to show a wide camera whole in a vertical clip) and a blurred copy of
  the picture fills the frame behind it. Click any slider's value to type an exact number.
- **Captions that are easy to fix.** Captions are blocks on the timeline: drag to move,
  drag edges to re-time, double-click to fix the text. Style presets for the look, with
  any installed font and any weight (or any thickness on a variable font). The box
  behind the spoken word glides from word to word with a quick spring.
- **Review fast.** Mark clips Use (U) or Rejected (X) and jump to the next, then export
  every clip marked Use into one folder in one go.
- **Frames and thumbnails.** Save any frame as a PNG or JPEG (⇧⌘S), or grab frames with G
  and save them all at once. Each clip gets a thumbnail: pick its frame from the clip,
  anywhere in the recording, or a picture file, then add its title (starting from your
  caption style), a dark fade, your logo, and brightness / contrast / saturation.
- **Export** vertical, square or wide video with burned-in captions (and a thumbnail
  beside it), audio only, or an .srt file.

## Download

[**Download Winnow.dmg**](https://github.com/hiasen99/winnow/releases/latest/download/Winnow.dmg)
— signed and notarized. Needs a Mac with Apple silicon (M1 or later) on **macOS 26** or later.

Open the disk image and drag Winnow to Applications.

From 1.6 on, Winnow checks this repository for a newer release when it opens (and about
once a day while it stays open) and shows a banner when one is out, with the release
notes and a download link. *Winnow → Check for Updates…* checks right away. The check
asks GitHub only for the latest release and sends nothing about you or your projects;
turn it off in Winnow → Settings.

## Claude

- **Find Clips** sends only the transcript text, and only when you press the button.
  Add an API key from [console.anthropic.com](https://console.anthropic.com) in
  Winnow → Settings. It's stored only on your Mac.
- **Claude desktop can work in Winnow directly** through MCP: read projects and
  transcripts, make and trim clips, fix captions and export. Winnow runs in the
  background while Claude works, on its own project, so your window never changes
  underneath you (open the same project and you work on it together, live). Add this to Claude's MCP
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

Word timing uses a Core ML conversion of wav2vec 2.0 (base, LibriSpeech 960h) from
fairseq / torchaudio (MIT License), downloaded from this repository's `aligner-1` release.
