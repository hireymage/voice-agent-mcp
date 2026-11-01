# Voice Agent MCP

An iPhone app for talking to the AI model, speech services and MCP tools you set up yourself. It has no account and no server of its own: everything runs on the phone and your conversation goes only to the services you add.

The interface is in English and Czech.

## What it does

- **Your own model:** OpenAI Chat Completions and Responses, Anthropic, Google Gemini, anything OpenAI-compatible (Ollama, LM Studio, vLLM and others), or Apple's on-device model on iPhones with Apple Intelligence. The main agent and a subagent can each use a different model.
- **Natural conversation:** the app hears when you finish, reads the answer aloud sentence by sentence, and stops when you talk over it. Subagents can start looking things up while you are still speaking.
- **Your own speech services:** Apple, OpenAI-compatible services, whisper.cpp and ElevenLabs for speech to text; Apple, OpenAI-compatible services, Piper and ElevenLabs for text to speech. Save as many services as you like and try each one in Settings.
- **MCP tools:** HTTP (Streamable HTTP) servers with custom headers and `mcp.json` import. Any single tool can be turned off. Local stdio servers cannot run on an iPhone.
- **iPhone tools:** calendar, reminders and contacts, each off until you turn it on.
- **Profiles:** several agents, each with its own soul, MCP servers and spoken or text-only replies.

## Build it

Requires Xcode 27 or later. The app targets iOS 17; Apple's on-device model needs iOS 26 or later.

1. Open `VoiceAgent.xcodeproj`.
2. In the target's Signing & Capabilities, choose your own team and change the bundle identifier.
3. Run on a device or simulator.

```bash
xcodebuild test -project VoiceAgent.xcodeproj -scheme VoiceAgent -destination 'platform=iOS Simulator,name=iPhone 18 Pro'
```

`LiveTests` run against real servers and are skipped unless the `TEST_RUNNER_LIVE_*` environment variables are set. Xcode sometimes does not return after the tests finish; the result is on the log line `Test Suite 'All tests' passed`.

CarPlay code is included, but a real car needs the voice-based conversation entitlement from Apple, so `CarPlay.entitlements` applies only to the simulator.


## Version numbers

Run `./set-version.sh` before each build. It sets the version to `1.year.week` and the build to `day.hour` from the current date, for example `1.26.44` (`7.15`): a two-digit year, a two-digit ISO week, and Monday as day 1. Apple allows at most three numbers in each field.

## Privacy

The app collects nothing. API keys stay in the iOS Keychain. See the [privacy policy](https://hireymage.github.io/voice-agent/privacy.html) and [support page](https://hireymage.github.io/voice-agent/).

## License

[MIT](LICENSE). The license covers the code. It gives no right to the app's name or icon.
