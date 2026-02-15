# Quotio/Views/Screens/SettingsScreen.swift

[← Back to Module](../modules/Quotio-Views-Screens/MODULE.md) | [← Back to INDEX](../INDEX.md)

## Overview

- **Lines:** 3051
- **Language:** Swift
- **Symbols:** 60
- **Public symbols:** 0

## Symbol Table

| Line | Kind | Name | Visibility | Signature |
| ---- | ---- | ---- | ---------- | --------- |
| 9 | struct | SettingsScreen | (internal) | `struct SettingsScreen` |
| 111 | struct | OperatingModeSection | (internal) | `struct OperatingModeSection` |
| 176 | fn | handleModeSelection | (private) | `private func handleModeSelection(_ mode: Operat...` |
| 195 | fn | switchToMode | (private) | `private func switchToMode(_ mode: OperatingMode)` |
| 210 | struct | RemoteServerSection | (internal) | `struct RemoteServerSection` |
| 330 | fn | saveRemoteConfig | (private) | `private func saveRemoteConfig(_ config: RemoteC...` |
| 338 | fn | reconnect | (private) | `private func reconnect()` |
| 353 | struct | UnifiedProxySettingsSection | (internal) | `struct UnifiedProxySettingsSection` |
| 573 | fn | loadConfig | (private) | `private func loadConfig() async` |
| 620 | fn | saveProxyURL | (private) | `private func saveProxyURL() async` |
| 638 | fn | saveRoutingStrategy | (private) | `private func saveRoutingStrategy(_ strategy: St...` |
| 647 | fn | saveSwitchProject | (private) | `private func saveSwitchProject(_ enabled: Bool)...` |
| 656 | fn | saveSwitchPreviewModel | (private) | `private func saveSwitchPreviewModel(_ enabled: ...` |
| 665 | fn | saveRequestRetry | (private) | `private func saveRequestRetry(_ count: Int) async` |
| 674 | fn | saveMaxRetryInterval | (private) | `private func saveMaxRetryInterval(_ seconds: In...` |
| 683 | fn | saveLoggingToFile | (private) | `private func saveLoggingToFile(_ enabled: Bool)...` |
| 692 | fn | saveRequestLog | (private) | `private func saveRequestLog(_ enabled: Bool) async` |
| 701 | fn | saveDebugMode | (private) | `private func saveDebugMode(_ enabled: Bool) async` |
| 714 | struct | LocalProxyServerSection | (internal) | `struct LocalProxyServerSection` |
| 788 | struct | NetworkAccessSection | (internal) | `struct NetworkAccessSection` |
| 822 | struct | LocalPathsSection | (internal) | `struct LocalPathsSection` |
| 846 | struct | PathLabel | (internal) | `struct PathLabel` |
| 870 | struct | NotificationSettingsSection | (internal) | `struct NotificationSettingsSection` |
| 940 | struct | QuotaDisplaySettingsSection | (internal) | `struct QuotaDisplaySettingsSection` |
| 982 | struct | RefreshCadenceSettingsSection | (internal) | `struct RefreshCadenceSettingsSection` |
| 1021 | struct | UpdateSettingsSection | (internal) | `struct UpdateSettingsSection` |
| 1063 | struct | ProxyUpdateSettingsSection | (internal) | `struct ProxyUpdateSettingsSection` |
| 1223 | fn | checkForUpdate | (private) | `private func checkForUpdate()` |
| 1237 | fn | performUpgrade | (private) | `private func performUpgrade(to version: ProxyVe...` |
| 1256 | struct | ProxyVersionManagerSheet | (internal) | `struct ProxyVersionManagerSheet` |
| 1415 | fn | sectionHeader | (private) | `@ViewBuilder   private func sectionHeader(_ tit...` |
| 1430 | fn | isVersionInstalled | (private) | `private func isVersionInstalled(_ version: Stri...` |
| 1434 | fn | refreshInstalledVersions | (private) | `private func refreshInstalledVersions()` |
| 1438 | fn | loadReleases | (private) | `private func loadReleases() async` |
| 1452 | fn | installVersion | (private) | `private func installVersion(_ release: GitHubRe...` |
| 1470 | fn | performInstall | (private) | `private func performInstall(_ release: GitHubRe...` |
| 1491 | fn | activateVersion | (private) | `private func activateVersion(_ version: String)` |
| 1509 | fn | deleteVersion | (private) | `private func deleteVersion(_ version: String)` |
| 1522 | struct | InstalledVersionRow | (private) | `struct InstalledVersionRow` |
| 1580 | struct | AvailableVersionRow | (private) | `struct AvailableVersionRow` |
| 1666 | fn | formatDate | (private) | `private func formatDate(_ isoString: String) ->...` |
| 1684 | struct | MenuBarSettingsSection | (internal) | `struct MenuBarSettingsSection` |
| 1825 | struct | AppearanceSettingsSection | (internal) | `struct AppearanceSettingsSection` |
| 1854 | struct | PrivacySettingsSection | (internal) | `struct PrivacySettingsSection` |
| 1876 | struct | GeneralSettingsTab | (internal) | `struct GeneralSettingsTab` |
| 1915 | struct | AboutTab | (internal) | `struct AboutTab` |
| 1942 | struct | AboutScreen | (internal) | `struct AboutScreen` |
| 2157 | struct | AboutUpdateSection | (internal) | `struct AboutUpdateSection` |
| 2213 | struct | AboutProxyUpdateSection | (internal) | `struct AboutProxyUpdateSection` |
| 2366 | fn | checkForUpdate | (private) | `private func checkForUpdate()` |
| 2380 | fn | performUpgrade | (private) | `private func performUpgrade(to version: ProxyVe...` |
| 2399 | struct | VersionBadge | (internal) | `struct VersionBadge` |
| 2451 | struct | AboutUpdateCard | (internal) | `struct AboutUpdateCard` |
| 2542 | struct | AboutProxyUpdateCard | (internal) | `struct AboutProxyUpdateCard` |
| 2716 | fn | checkForUpdate | (private) | `private func checkForUpdate()` |
| 2730 | fn | performUpgrade | (private) | `private func performUpgrade(to version: ProxyVe...` |
| 2749 | struct | LinkCard | (internal) | `struct LinkCard` |
| 2836 | struct | ManagementKeyRow | (internal) | `struct ManagementKeyRow` |
| 2930 | struct | LaunchAtLoginToggle | (internal) | `struct LaunchAtLoginToggle` |
| 2988 | struct | UsageDisplaySettingsSection | (internal) | `struct UsageDisplaySettingsSection` |

