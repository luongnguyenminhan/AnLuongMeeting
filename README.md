# Celesnity Meeting

Celesnity Meeting is a private macOS menu-bar workspace for recording meetings, generating transcripts, and turning them into readable meeting notes.

## What it does

- Records system audio and microphone audio into a stereo `.m4a` file.
- Stores recordings, transcripts, and meeting notes locally in `~/Recordings`.
- Generates Vietnamese transcripts and Markdown meeting notes with Gemini when an API key is configured.
- Provides a searchable Library with permanent-delete confirmation, Markdown note rendering, and transcript review.

## Build and install

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer ./make-app.sh
mv "Celesnity Meeting.app" "/Applications/Celesnity Meeting.app"
open "/Applications/Celesnity Meeting.app"
```

On the first launch, approve Microphone and Screen Recording permissions in **System Settings → Privacy & Security**. Fully quit and relaunch after enabling Screen Recording.

## Local settings

```bash
defaults write com.celesnity.meeting MicGainDb -float 6
defaults write com.celesnity.meeting DisableAEC -bool true
```

The Gemini API key is stored in the macOS Keychain under the Celesnity Meeting app identity.
