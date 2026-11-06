# Changelog

## 1.26.45

Version numbers now follow the date: `1.year.week`, build `day.hour` (see `set-version.sh`).

### Fixed

- **Text fields lost what was typed.** In a newly added server, profile or speech service, moving to the next field put the old value back, and the soul text box cleared itself. Editors now read their item straight from the settings instead of a copy handed over by the list.
- **Piper clicked between sentences.** The Piper server sends a line of text after the audio; the app played those bytes as sound. A WAV header is now changed only when its size is missing or wrong.
- **The chat jumped and flickered while an answer was written,** and after a few short messages it stopped following the end. The list no longer guesses row heights, the scroll view itself holds the end, and only scrolling up by hand stops following.
- **A second message stopped the work on the first.** A message sent before the agent answers now waits for its turn, the work on the earlier one (subagents included) goes on, and both are answered.

### New

- **Subagents work in the background.** The main agent answers at once and keeps talking; a subagent's report comes in as its own message when nobody is speaking. Stop and talking over the agent end only what it says.
- **Subagent counter** next to the state: grey at zero, in colour with the number of subagents at work.
- **Interrupt after the first word** (Settings → Conversation → When): the agent stops once speech recognition writes a word and the phone's sound classifier hears speech, so Whisper's made-up lines for noise do not stop it.
- **Thinking level per profile** for the main agent and the subagent: model default, off, low, medium or high, sent to each API in the form it understands, with a fallback when a server refuses one.
- **Subagent soul per profile,** set like the main soul (text or loaded through MCP). The former shared subagent instructions moved into every profile.
- **The keyboard closes** when you tap anywhere outside a text field.
