# FOI YouTube Surround

Play a YouTube video's original 5.1 soundtrack through your surround system while you watch in Safari. The extension adds a **5.1** button between captions and the Settings gear. The video stays in the tab, so you can pause, seek, or change the volume with the usual YouTube controls.

**Made by Sourish Mukherjee (@msourish), FOI Studios, Kolkata.** [GitHub profile](https://github.com/msourish) · [FOI Studios](https://foistudios.in)

[Download the Mac app for Apple silicon](https://github.com/msourish/FOI-YouTube-Surround/releases/download/v1.0.3/FOI-YouTube-Surround-1.0.3-macOS-arm64.zip) · [Release notes](https://github.com/msourish/FOI-YouTube-Surround/releases/tag/v1.0.3)

## How it works

I built this for the Sony 5.1 system I use in the studio. Safari handles the picture. When you choose **5.1**, a local companion looks for a six-channel track on the same public YouTube upload. It verifies the speaker layout, follows the video's position, and sends decoded audio to BlackHole 16ch. FOI Surround Monitor takes those six channels and encodes them as Dolby Digital (AC-3) for the receiver.

- **Original surround.** Supported sources include AC-3, E-AC-3 and compatible six-channel AAC. Stereo-only uploads continue with normal YouTube audio.
- **In-tab controls.** Play, pause, seek, volume, mute and playback speed follow the YouTube player. Click **5.1** again to switch back. The Safari toolbar icon also opens the control.
- **One active surround tab.** Selecting 5.1 in another tab releases the previous tab. YouTube uses its own audio during ads.
- **Local playback.** The extension asks for access to YouTube. The companion uses the public video ID to request audio from YouTube and its media servers. You do not need to sign in to the companion or paste a video link into another player.

## 1. Set up the monitor

You need an Apple silicon Mac, macOS 13 or later, Safari, and a working FOI Surround Monitor output. The studio setup used a Mac mini M4, an HDMI-to-optical extractor, and a Sony HT-S20R. Other setups need a compatible Mac HDMI output path and a receiver or soundbar that decodes Dolby Digital 5.1.

1. Install **FOI Surround Monitor** using its guide. Its public beta builds from source and uses **BlackHole 16ch** and **FFmpeg**. The guide includes the required tools, cabling and speaker test. [Monitor installation guide](https://github.com/msourish/FOI-Surround-Monitor#2-build-and-install)
2. In **Audio MIDI Setup**, set BlackHole 16ch to **48,000 Hz**. Under **Configure Speakers**, choose **5.1 Surround** and assign channels 1–6 to front left, front right, centre, subwoofer, surround left and surround right, respectively. [Monitor routing guide](https://github.com/msourish/FOI-Surround-Monitor#3-set-up-audio-midi)
3. Open FOI Surround Monitor, select its **Fairlight 5.1** input mode, choose the physical HDMI device feeding your receiver or extractor, and click **Start**. The Safari companion sends audio directly to BlackHole 16ch, so you can keep the system output you normally use.

## 2. Install the Safari extension

1. Install **Python 3.11 or later** and **Node.js 22 or later**. If you already use Homebrew, run the following in Terminal. The standard Apple silicon Homebrew paths are recognized when the app starts from Finder. [Homebrew](https://brew.sh) · [yt-dlp runtime requirements](https://github.com/yt-dlp/yt-dlp/wiki/EJS)

   ```sh
   brew install python node
   ```

2. Download and unzip **FOI-YouTube-Surround-1.0.3-macOS-arm64.zip** from the release. Move **FOI YouTube Surround.app** to Applications or your own Applications folder, then open it. This is a locally signed development build. If Gatekeeper blocks the verified download, follow Apple's per-app **Open Anyway** procedure in **System Settings → Privacy & Security**. [GitHub release](https://github.com/msourish/FOI-YouTube-Surround/releases/tag/v1.0.3) · [Apple’s app-opening guide](https://support.apple.com/en-us/102445)
3. In **Safari → Settings → Advanced**, enable **Show features for web developers**. Then select **Developer → Allow unsigned extensions**. On Safari 16, enable **Show Develop menu in menu bar** and choose **Develop → Allow Unsigned Extensions**. Safari resets this switch when you quit. [Apple’s extension testing instructions](https://developer.apple.com/documentation/safariservices/running-your-safari-web-extension)
4. In the companion, click **Open Safari Extensions**. Enable **FOI YouTube Surround**, open a YouTube watch page, and allow the extension on **youtube.com** when prompted. Reload the page if it was already open.

## 3. Listen and verify

With the monitor running, open the test video below and click **5.1** beside the gear. Wait for **Original 5.1 · FOI Monitor**. Keep the listening level low for the first check. As the video calls each speaker, watch the corresponding monitor meter and listen at that speaker. [5.1 Dolby Surround Test on YouTube](https://www.youtube.com/watch?v=PqVCPE8_ntE)

In the studio test on 22 November 2026, version **1.0.2** played the video's original 48 kHz AC-3 track from Safari. FOI's monitor recorded the correct speaker as the strongest channel in **127 of 127** sampled windows. These readings were taken at the monitor input. Version **1.0.3** is the public package.

| Speaker named in the video | Correct readings |
| --- | ---: |
| Front left | 23 / 23 |
| Front right | 23 / 23 |
| Centre | 28 / 28 |
| Subwoofer (LFE) | 11 / 11 |
| Surround left | 21 / 21 |
| Surround right | 21 / 21 |

## Troubleshooting

| What you see or hear | What to check |
| --- | --- |
| No 5.1 button | Use a desktop YouTube watch page. Check YouTube site access and Safari's unsigned-extension switch, then reload. |
| A message says to start the monitor | Open **FOI Surround Monitor**, select the six-channel input mode and your HDMI output, and press **Start**. The companion checks for a running output before it switches the tab. |
| A video stays in stereo | Some uploads only have stereo, even when their titles say “5.1”. YouTube can also decline a request for the surround stream. Try the speaker test above or use **Retry 5.1**. The current version supports public, recorded YouTube videos. |
| Playback takes a while to switch | If macOS cannot stream the audio directly, the companion can buffer a temporary copy of the original audio, up to 512 MiB. It keeps 128 MiB of disk space free and removes the temporary audio when the session ends. |
| Picture and sound pause together | Try **1080p** in YouTube’s quality menu. Video resolution and the companion’s 5.1 audio selection are separate. |
| The picture moves but the sound briefly drops | The companion can briefly mute while it seeks to bring the audio back in sync with the video. Repeated dropouts may also mean the surround stream is stalling. |
| The wrong speaker plays a cue | Check BlackHole’s 1–6 assignments, the monitor input mode, and the receiver's surround settings. [Speaker setup and test](https://github.com/msourish/FOI-Surround-Monitor#5-check-your-speakers) |

## Build from source

Install Apple's Command Line Tools with `xcode-select --install`. Run the build script from the extracted source folder or a clone of this repository on an Apple silicon Mac.

```sh
bash build.sh
```

The script produces **FOI YouTube Surround.app** and a ZIP in the project folder, then verifies the extracted app's code signature. If you have an Apple Development signing identity you can supply it through `CODE_SIGN_IDENTITY`. The same monitor and audio runtimes are required for playback.

This project includes yt-dlp and its JavaScript components. [Third-party notices](THIRD-PARTY-NOTICES.md)
