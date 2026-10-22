# Murmur

A free, private Wispr Flow replacement for macOS. Hold **fn**, talk, let go, and your words are typed into whatever text field you're in, with the ums, stutters and false starts removed.

Everything runs on your Mac. Speech recognition uses Apple's on-device speech model and cleanup uses Apple Intelligence's on-device model. No account, no subscription, nothing leaves the machine.

## Using it

| Do this | To |
| --- | --- |
| Hold **fn**, speak, release | Dictate. Text is pasted where your cursor is |
| Hold **fn**, press **Space** | Hands-free mode: let go and keep talking. Press **fn** again to finish |
| **Esc** while dictating | Cancel |
| Say "new paragraph" or "new line" as its own phrase | Insert a line break |

While you speak, a pill at the bottom of the screen shows a live waveform and the words as they're recognised.

The waveform icon in the menu bar has:

- **Recent Dictations**: click one to copy it again, handy if a paste missed.
- **AI Cleanup**: on-device polish (removes "like", "you know", applies "no wait, I mean…" corrections, fixes punctuation). Turn it off for raw transcription with basic filler removal only.
- **Edit Personal Dictionary…**: names and jargon you want spelled your way (one per line). Used by both the recogniser and the cleanup.
- Sounds, adding a trailing space after each dictation, and Launch at Login.

## First run

macOS asks for two permissions:

1. **Microphone**: click Allow.
2. **Accessibility**: needed to detect the fn key and to paste. Open *System Settings → Privacy & Security → Accessibility* and turn on **Murmur**. It starts working within a couple of seconds, no restart needed.

If pressing fn opens the emoji picker or changes the input source, set *System Settings → Keyboard → "Press 🌐 key to"* to **Do Nothing**. The menu offers a shortcut to this if needed.

Quit Wispr Flow while using Murmur, otherwise both will react to fn.

## Building

Needs macOS 26 on Apple silicon and the Xcode Command Line Tools (`xcode-select --install`). Full Xcode isn't required.

```bash
./build.sh            # builds release/Murmur.app
./build.sh --install  # also copies it to /Applications and launches it
```

The app is ad-hoc signed with a requirement that checks only its bundle ID (`com.harrydavies.murmur`), so macOS keeps its permissions when you rebuild. The trade-off is that macOS would also give those permissions to any other app using that same bundle ID. That's fine for a personal tool.

## How it works

| File | Job |
| --- | --- |
| `HotkeyMonitor.swift` | System-wide event tap that watches the fn key, fn+Space and Esc |
| `AudioCapture.swift` | Microphone capture and conversion to the speech model's format |
| `Transcriber.swift` | Apple's `SpeechAnalyzer` / `SpeechTranscriber` with live partial results |
| `TextCleaner.swift` | Rule-based cleanup that always runs: fillers, repeated words, spacing, capitals, line-break commands |
| `AICleaner.swift` | Optional on-device language model pass, with checks that reject replies instead of cleanups |
| `Paster.swift` | Pastes via the clipboard, then restores what you had copied before |
| `Overlay.swift` | The floating pill |
| `DictationController.swift` | Ties it all together |

The AI pass is guarded. If the model's output contains words you didn't say, drops most of what you said, starts with "Sure, here's…", or takes longer than 4 seconds, Murmur pastes the rule-cleaned text instead. Dictating "what time does the shop close" types the question rather than an invented answer.

### Developer commands

```bash
release/Murmur.app/Contents/MacOS/Murmur --selftest                # cleanup rule tests
release/Murmur.app/Contents/MacOS/Murmur --clean "um so I I think"  # run cleanup on text
release/Murmur.app/Contents/MacOS/Murmur --transcribe file.wav      # full pipeline on an audio file
release/Murmur.app/Contents/MacOS/Murmur --overlay-demo             # animate the pill
```

## Troubleshooting

- **Nothing happens when I hold fn.** Check the menu bar icon. A slashed waveform means a permission is missing, and the menu says which one. If Accessibility is already on but it still doesn't work, toggle Murmur off and on in that list.
- **Text is copied but not pasted.** A password field or another secure input is active, and macOS blocks simulated typing there. Press ⌘V.
- **AI Cleanup is greyed out.** Turn on Apple Intelligence in System Settings.
