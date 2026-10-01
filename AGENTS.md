# PIAAR Work Development Guide

## Project Goal

This project is evolving from "PIAAR Translator" into "PIAAR Work",
an internal productivity application for PIAAR HOLDINGS.

The existing translator is a production feature and must remain functional.

Future major features:
- Translator
- Todo
- macOS / iOS synchronization
- iOS Lock Screen Live Activity
- App Intents / Shortcuts
- CloudKit synchronization

---

## Existing Project

Platform:
- macOS 14.3+
- Swift 5
- SwiftUI

Current Bundle Identifier:
- com.piaar.PIAAR-Translator

Important existing files:
- PIAAR_TranslatorApp.swift
- ContentView.swift
- TranslatorViewModel.swift
- OpenAIService.swift
- GlobalHotKeyManager.swift
- KeychainManager.swift
- PopupWindowController.swift
- LaunchAtLoginManager.swift
- PIAARTerminology.swift

---

## Critical Rules

### 1. Do not break the Translator

Existing translation behavior must continue working.

Do not rewrite working translator code unless necessary.

When modifying existing behavior:
1. Explain why.
2. Make the smallest possible change.
3. Preserve existing behavior.

---

### 2. Preserve User Settings

Never intentionally reset user preferences during an update.

Global shortcut settings currently use UserDefaults:

- PIAARHotKeyKeyCode
- PIAARHotKeyModifiers

Do not rename or delete these keys without a migration strategy.

API credentials stored in Keychain must remain compatible with
previous versions.

Application updates must preserve:
- shortcut settings
- API settings
- user preferences
- user data

---

### 3. Bundle Identifier Stability

Do not change the existing Bundle Identifier without explicitly
warning the developer.

Current:
com.piaar.PIAAR-Translator

A Bundle ID change may cause existing UserDefaults, Keychain access,
permissions, or update behavior to change.

If the product is renamed to PIAAR Work, prefer changing the
display name first while keeping compatibility.

---

### 4. Architecture

Prefer:
- SwiftUI
- MVVM where appropriate
- small focused files
- reusable services
- async/await
- Apple native frameworks

Avoid unnecessary third-party dependencies.

Do not place new large features directly inside ContentView.swift.

Create separate modules/files such as:

Features/
  Translator/
  Todo/

Services/

Models/

Shared/

---

### 5. Todo Architecture

Todo should be designed for eventual support on:
- macOS
- iPhone
- Widget
- Live Activity
- App Intents / Shortcuts

Todo data must not be stored only inside the application bundle.

Design the persistence layer so CloudKit synchronization can be
added safely.

---

### 6. iOS / macOS

Do not add iOS-specific frameworks directly to shared macOS code.

Use:
#if os(macOS)
#endif

and

#if os(iOS)
#endif

when platform-specific behavior is required.

Shared models and business logic should remain platform independent
where practical.

---

### 7. UI

Keep the existing PIAAR Translator UI behavior unless the task
explicitly requests redesign.

PIAAR Work should eventually have:
- Translator
- Todo

as clearly separated features.

Prefer simple, compact internal-tool UI.

---

### 8. Security

Never hardcode:
- OpenAI API keys
- passwords
- access tokens
- private credentials

Sensitive credentials must use Keychain or another appropriate
secure storage mechanism.

---

### 9. Build Verification

After code changes, verify the project builds whenever possible.

Use xcodebuild for validation.

Do not consider a task complete if obvious compiler errors remain.

If build verification cannot be completed, clearly state why.

---

## Working Style

Before a large modification:
1. Inspect the relevant existing files.
2. Explain the proposed architecture briefly.
3. Modify the minimum required files.
4. Build/test.
5. Summarize changed files.

Do not delete existing functionality just to simplify implementation.

When uncertain about an existing behavior, inspect the code before
changing it.


## Testing Policy

- Do not create, run, modify, or seed UI tests unless explicitly requested.
- The project does not use a UI Test target. Keep the Unit Test target.
- Validate changes with all Unit Tests, Debug build, Release build, and
  `git diff --check`.
- UI behavior is manually verified by the user.
- Never add test-only Production UI or change Production behavior solely to
  support automated UI testing.
