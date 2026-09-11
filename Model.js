// Pure helpers for the Google Drives panel: parsing the status helper's
// JSON, and formatting bytes/percent/time for display. No Quickshell
// imports here so this file loads unmodified under both QML (`import
// "Model.js" as Model`) and Node (`require("./Model.js")`) — see
// test/model.test.js.

function parseAccounts(raw) {
  var text = String(raw || "").trim()
  if (text === "") return defaultResult()
  try {
    var parsed = JSON.parse(text)
    if (!parsed || typeof parsed !== "object") return defaultResult()
    parsed.accounts = Array.isArray(parsed.accounts) ? parsed.accounts.map(normalizeAccount) : []
    if (typeof parsed.rcloneInstalled !== "boolean") parsed.rcloneInstalled = false
    if (typeof parsed.ok !== "boolean") parsed.ok = true
    return parsed
  } catch (e) {
    var failed = defaultResult()
    failed.ok = false
    failed.lastError = "Failed to parse Google Drives status"
    return failed
  }
}

function normalizeAccount(account) {
  account = account || {}
  return {
    id: String(account.id || ""),
    displayName: String(account.displayName || account.id || "Account"),
    authenticated: account.authenticated === true,
    active: account.active === true,
    statusText: String(account.statusText || "Unknown"),
    mountPath: String(account.mountPath || ""),
    usedBytes: Number(account.usedBytes || 0),
    quotaBytes: Number(account.quotaBytes || 0),
    quotaKnown: account.quotaKnown === true,
    lastError: String(account.lastError || "")
  }
}

function defaultResult() {
  return { ok: true, rcloneInstalled: false, accounts: [], lastError: "" }
}

// Aggregate state across every configured account, for the bar icon/tooltip:
// which color to use, and the one-line summary the icon's tooltip shows.
function aggregateState(accounts) {
  accounts = accounts || []
  if (accounts.length === 0) return "empty"
  if (accounts.some(function(a) { return a.lastError !== "" })) return "error"
  if (accounts.some(function(a) { return a.authenticated && a.active })) return "mounted"
  if (accounts.every(function(a) { return a.authenticated && !a.active })) return "paused"
  return "attention"
}

function aggregateSummary(accounts) {
  accounts = accounts || []
  if (accounts.length === 0) return "No accounts configured"
  var errored = accounts.filter(function(a) { return a.lastError !== "" }).length
  if (errored > 0) return errored + " of " + accounts.length + " account" + (accounts.length === 1 ? "" : "s") + " need attention"
  var mounted = accounts.filter(function(a) { return a.authenticated && a.active }).length
  if (mounted === accounts.length) return "All " + accounts.length + " account" + (accounts.length === 1 ? "" : "s") + " mounted"
  if (mounted === 0) return "All paused"
  return mounted + " of " + accounts.length + " mounted"
}

function totalUsedBytes(accounts) {
  return (accounts || []).reduce(function(sum, a) { return sum + Number(a.usedBytes || 0) }, 0)
}

function formatBytes(bytes) {
  var value = Number(bytes || 0)
  if (!isFinite(value) || value <= 0) return "0 B"
  var units = ["B", "KB", "MB", "GB", "TB"]
  var index = 0
  while (value >= 1000 && index < units.length - 1) {
    value = value / 1000
    index++
  }
  var decimals = value >= 100 || index === 0 ? 0 : (value >= 10 ? 1 : 2)
  return value.toFixed(decimals).replace(/\.0+$/, "").replace(/(\.\d)0$/, "$1") + " " + units[index]
}

function usageText(usedBytes, quotaBytes, quotaKnown) {
  if (quotaKnown && Number(quotaBytes || 0) > 0) {
    return formatBytes(usedBytes) + " of " + formatBytes(quotaBytes)
  }
  return formatBytes(usedBytes)
}

if (typeof module !== "undefined") {
  module.exports = {
    parseAccounts: parseAccounts,
    normalizeAccount: normalizeAccount,
    defaultResult: defaultResult,
    aggregateState: aggregateState,
    aggregateSummary: aggregateSummary,
    totalUsedBytes: totalUsedBytes,
    formatBytes: formatBytes,
    usageText: usageText
  }
}
