# Quotio/ViewModels/QuotaViewModel.swift

[← Back to Module](../modules/root/MODULE.md) | [← Back to INDEX](../INDEX.md)

## Overview

- **Lines:** 1917
- **Language:** Swift
- **Symbols:** 92
- **Public symbols:** 0

## Symbol Table

| Line | Kind | Name | Visibility | Signature |
| ---- | ---- | ---- | ---------- | --------- |
| 11 | class | QuotaViewModel | (internal) | `class QuotaViewModel` |
| 131 | fn | loadDisabledAuthFiles | (private) | `private func loadDisabledAuthFiles() -> Set<Str...` |
| 137 | fn | saveDisabledAuthFiles | (private) | `private func saveDisabledAuthFiles(_ names: Set...` |
| 142 | fn | syncDisabledStatesToBackend | (private) | `private func syncDisabledStatesToBackend() async` |
| 161 | fn | notifyQuotaDataChanged | (private) | `private func notifyQuotaDataChanged()` |
| 164 | method | init | (internal) | `init()` |
| 174 | fn | setupProxyURLObserver | (private) | `private func setupProxyURLObserver()` |
| 190 | fn | normalizedProxyURL | (private) | `private func normalizedProxyURL(_ rawValue: Str...` |
| 202 | fn | updateProxyConfiguration | (internal) | `func updateProxyConfiguration() async` |
| 215 | fn | setupRefreshCadenceCallback | (private) | `private func setupRefreshCadenceCallback()` |
| 223 | fn | setupWarmupCallback | (private) | `private func setupWarmupCallback()` |
| 241 | fn | restartAutoRefresh | (private) | `private func restartAutoRefresh()` |
| 253 | fn | initialize | (internal) | `func initialize() async` |
| 263 | fn | initializeFullMode | (private) | `private func initializeFullMode() async` |
| 279 | fn | checkForProxyUpgrade | (private) | `private func checkForProxyUpgrade() async` |
| 284 | fn | initializeQuotaOnlyMode | (private) | `private func initializeQuotaOnlyMode() async` |
| 294 | fn | initializeRemoteMode | (private) | `private func initializeRemoteMode() async` |
| 322 | fn | setupRemoteAPIClient | (private) | `private func setupRemoteAPIClient(config: Remot...` |
| 330 | fn | reconnectRemote | (internal) | `func reconnectRemote() async` |
| 339 | fn | loadDirectAuthFiles | (internal) | `func loadDirectAuthFiles() async` |
| 345 | fn | refreshQuotasDirectly | (internal) | `func refreshQuotasDirectly() async` |
| 373 | fn | autoSelectMenuBarItems | (private) | `private func autoSelectMenuBarItems()` |
| 407 | fn | syncMenuBarSelection | (internal) | `func syncMenuBarSelection()` |
| 414 | fn | refreshClaudeCodeQuotasInternal | (private) | `private func refreshClaudeCodeQuotasInternal() ...` |
| 435 | fn | refreshCursorQuotasInternal | (private) | `private func refreshCursorQuotasInternal() async` |
| 446 | fn | refreshCodexCLIQuotasInternal | (private) | `private func refreshCodexCLIQuotasInternal() async` |
| 462 | fn | refreshGeminiCLIQuotasInternal | (private) | `private func refreshGeminiCLIQuotasInternal() a...` |
| 480 | fn | refreshGlmQuotasInternal | (private) | `private func refreshGlmQuotasInternal() async` |
| 490 | fn | refreshWarpQuotasInternal | (private) | `private func refreshWarpQuotasInternal() async` |
| 514 | fn | refreshTraeQuotasInternal | (private) | `private func refreshTraeQuotasInternal() async` |
| 524 | fn | refreshKiroQuotasInternal | (private) | `private func refreshKiroQuotasInternal() async` |
| 530 | fn | cleanName | (internal) | `func cleanName(_ name: String) -> String` |
| 580 | fn | startQuotaOnlyAutoRefresh | (private) | `private func startQuotaOnlyAutoRefresh()` |
| 598 | fn | startQuotaAutoRefreshWithoutProxy | (private) | `private func startQuotaAutoRefreshWithoutProxy()` |
| 617 | fn | isWarmupEnabled | (internal) | `func isWarmupEnabled(for provider: AIProvider, ...` |
| 621 | fn | warmupStatus | (internal) | `func warmupStatus(provider: AIProvider, account...` |
| 626 | fn | warmupNextRunDate | (internal) | `func warmupNextRunDate(provider: AIProvider, ac...` |
| 631 | fn | toggleWarmup | (internal) | `func toggleWarmup(for provider: AIProvider, acc...` |
| 640 | fn | setWarmupEnabled | (internal) | `func setWarmupEnabled(_ enabled: Bool, provider...` |
| 652 | fn | nextDailyRunDate | (private) | `private func nextDailyRunDate(minutes: Int, now...` |
| 663 | fn | restartWarmupScheduler | (private) | `private func restartWarmupScheduler()` |
| 696 | fn | runWarmupCycle | (private) | `private func runWarmupCycle() async` |
| 759 | fn | warmupAccount | (private) | `private func warmupAccount(provider: AIProvider...` |
| 804 | fn | warmupAccount | (private) | `private func warmupAccount(     provider: AIPro...` |
| 865 | fn | fetchWarmupModels | (private) | `private func fetchWarmupModels(     provider: A...` |
| 889 | fn | warmupAvailableModels | (internal) | `func warmupAvailableModels(provider: AIProvider...` |
| 902 | fn | warmupAuthInfo | (private) | `private func warmupAuthInfo(provider: AIProvide...` |
| 924 | fn | warmupTargets | (private) | `private func warmupTargets() -> [WarmupAccountKey]` |
| 938 | fn | updateWarmupStatus | (private) | `private func updateWarmupStatus(for key: Warmup...` |
| 967 | fn | startProxy | (internal) | `func startProxy() async` |
| 1011 | fn | stopProxy | (internal) | `func stopProxy()` |
| 1039 | fn | toggleProxy | (internal) | `func toggleProxy() async` |
| 1047 | fn | setupAPIClient | (private) | `private func setupAPIClient()` |
| 1054 | fn | startAutoRefresh | (private) | `private func startAutoRefresh()` |
| 1091 | fn | attemptProxyRecovery | (private) | `private func attemptProxyRecovery() async` |
| 1107 | fn | refreshData | (internal) | `func refreshData() async` |
| 1154 | fn | manualRefresh | (internal) | `func manualRefresh() async` |
| 1165 | fn | refreshAllQuotas | (internal) | `func refreshAllQuotas() async` |
| 1201 | fn | refreshQuotasUnified | (internal) | `func refreshQuotasUnified() async` |
| 1235 | fn | refreshAntigravityQuotasInternal | (private) | `private func refreshAntigravityQuotasInternal()...` |
| 1255 | fn | refreshAntigravityQuotasWithoutDetect | (private) | `private func refreshAntigravityQuotasWithoutDet...` |
| 1272 | fn | isAntigravityAccountActive | (internal) | `func isAntigravityAccountActive(email: String) ...` |
| 1277 | fn | switchAntigravityAccount | (internal) | `func switchAntigravityAccount(email: String) async` |
| 1287 | fn | beginAntigravitySwitch | (internal) | `func beginAntigravitySwitch(accountId: String, ...` |
| 1292 | fn | cancelAntigravitySwitch | (internal) | `func cancelAntigravitySwitch()` |
| 1297 | fn | dismissAntigravitySwitchResult | (internal) | `func dismissAntigravitySwitchResult()` |
| 1300 | fn | refreshOpenAIQuotasInternal | (private) | `private func refreshOpenAIQuotasInternal() async` |
| 1305 | fn | refreshCopilotQuotasInternal | (private) | `private func refreshCopilotQuotasInternal() async` |
| 1310 | fn | refreshQuotaForProvider | (internal) | `func refreshQuotaForProvider(_ provider: AIProv...` |
| 1345 | fn | refreshAutoDetectedProviders | (internal) | `func refreshAutoDetectedProviders() async` |
| 1352 | fn | startOAuth | (internal) | `func startOAuth(for provider: AIProvider, proje...` |
| 1395 | fn | startCopilotAuth | (private) | `private func startCopilotAuth() async` |
| 1412 | fn | startKiroAuth | (private) | `private func startKiroAuth(method: AuthCommand)...` |
| 1446 | fn | pollCopilotAuthCompletion | (private) | `private func pollCopilotAuthCompletion() async` |
| 1463 | fn | pollKiroAuthCompletion | (private) | `private func pollKiroAuthCompletion() async` |
| 1481 | fn | pollOAuthStatus | (private) | `private func pollOAuthStatus(state: String, pro...` |
| 1509 | fn | cancelOAuth | (internal) | `func cancelOAuth()` |
| 1513 | fn | deleteAuthFile | (internal) | `func deleteAuthFile(_ file: AuthFile) async` |
| 1549 | fn | toggleAuthFileDisabled | (internal) | `func toggleAuthFileDisabled(_ file: AuthFile) a...` |
| 1580 | fn | pruneMenuBarItems | (private) | `private func pruneMenuBarItems()` |
| 1616 | fn | importVertexServiceAccount | (internal) | `func importVertexServiceAccount(url: URL) async` |
| 1640 | fn | fetchAPIKeys | (internal) | `func fetchAPIKeys() async` |
| 1650 | fn | addAPIKey | (internal) | `func addAPIKey(_ key: String) async` |
| 1662 | fn | updateAPIKey | (internal) | `func updateAPIKey(old: String, new: String) async` |
| 1674 | fn | deleteAPIKey | (internal) | `func deleteAPIKey(_ key: String) async` |
| 1687 | fn | checkAccountStatusChanges | (private) | `private func checkAccountStatusChanges()` |
| 1708 | fn | checkQuotaNotifications | (internal) | `func checkQuotaNotifications()` |
| 1740 | fn | scanIDEsWithConsent | (internal) | `func scanIDEsWithConsent(options: IDEScanOption...` |
| 1810 | fn | savePersistedIDEQuotas | (private) | `private func savePersistedIDEQuotas()` |
| 1833 | fn | loadPersistedIDEQuotas | (private) | `private func loadPersistedIDEQuotas()` |
| 1895 | fn | shortenAccountKey | (private) | `private func shortenAccountKey(_ key: String) -...` |
| 1907 | struct | OAuthState | (internal) | `struct OAuthState` |

## Memory Markers

### 🟢 `NOTE` (line 271)

> checkForProxyUpgrade() is now called inside startProxy()

### 🟢 `NOTE` (line 344)

> Cursor and Trae are NOT auto-refreshed - user must use "Scan for IDEs" (issue #29)

### 🟢 `NOTE` (line 352)

> Cursor and Trae removed from auto-refresh to address privacy concerns (issue #29)

### 🟢 `NOTE` (line 1175)

> Cursor and Trae removed from auto-refresh (issue #29)

### 🟢 `NOTE` (line 1200)

> Cursor and Trae require explicit user scan (issue #29)

### 🟢 `NOTE` (line 1210)

> Cursor and Trae removed - require explicit scan (issue #29)

### 🟢 `NOTE` (line 1265)

> Don't call detectActiveAccount() here - already set by switch operation

