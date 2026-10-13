# macOS porting ledger

Every upstream file the Mac target excludes, gates, or twins. Re-check this
list after each `git merge upstream/main`.

| File | Rule | Reason | Mac side |
|---|---|---|---|
| Conduit/CarPlay/CarPlayVoiceSceneDelegate.swift | R2 | imports CarPlay | none needed |
| Conduit/CarPlay/CarPlayVoiceCoordinator.swift | R2 | imports CarPlay | ConduitMac/Stubs/CarPlayStubs.swift |
| Conduit/CarPlay/CarPlayBrowseTemplates.swift | R2 | imports CarPlay | none needed |
| Conduit/CarPlay/CarPlayVoiceTemplateFactory.swift | R2 | imports CarPlay | CarPlayVoiceControls copied to CarPlayStubs.swift |
| Conduit/CarPlay/PhoneScenePresence.swift | R2 | UIScene foreground check | ConduitMac/Stubs/PhoneScenePresence.swift |
| Conduit/Watch/WatchVoiceLink.swift | R2 | imports WatchConnectivity | ConduitMac/Stubs/WatchVoiceLinkStub.swift |
| Conduit/Voice/HermesNativeCalls.swift | R3 | CallKit/PushKit class | ConduitMac/Stubs/HermesNativeCallsStub.swift |
