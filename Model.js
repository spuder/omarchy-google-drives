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
    timerEnabled: account.timerEnabled === true,
    running: account.running === true,
    syncPath: String(account.syncPath || ""),
    lastSyncAt: Number(account.lastSyncAt || 0),
    lastSyncOk: account.lastSyncOk !== false,
    needsResync: account.needsResync === true,
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
  if (accounts.some(function(a) { return a.running })) return "syncing"
  if (accounts.every(function(a) { return a.authenticated && !a.timerEnabled })) return "paused"
  return "attention"
}

function aggregateSummary(accounts) {
  accounts = accounts || []
  if (accounts.length === 0) return "No accounts configured"
  var errored = accounts.filter(function(a) { return a.lastError !== "" }).length
  if (errored > 0) return errored + " of " + accounts.length + " account" + (accounts.length === 1 ? "" : "s") + " need attention"
  var scheduled = accounts.filter(function(a) { return a.authenticated && a.timerEnabled }).length
  if (scheduled === accounts.length) return "All " + accounts.length + " account" + (accounts.length === 1 ? "" : "s") + " syncing"
  if (scheduled === 0) return "Syncing paused"
  return scheduled + " of " + accounts.length + " syncing"
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

// One-line status for an account row: what's actually happening right now,
// in priority order (error already shown separately by the caller).
function statusText(account, nowSeconds) {
  account = account || {}
  if (!account.authenticated) return "Not signed in"
  if (account.running) return "Syncing…"
  if (account.needsResync) return account.timerEnabled ? "Waiting for first sync" : "Paused (never synced)"
  if (!account.timerEnabled) return "Paused"
  if (!account.lastSyncAt) return "Waiting for first sync"
  return "Synced " + relativeTime(account.lastSyncAt, nowSeconds)
}

function relativeTime(epochSeconds, nowSeconds) {
  var now = typeof nowSeconds === "number" ? nowSeconds : Math.floor(Date.now() / 1000)
  var delta = Math.max(0, now - Number(epochSeconds || 0))
  if (delta < 45) return "just now"
  if (delta < 90) return "1 minute ago"
  if (delta < 3600) return Math.round(delta / 60) + " minutes ago"
  if (delta < 5400) return "1 hour ago"
  if (delta < 86400) return Math.round(delta / 3600) + " hours ago"
  if (delta < 172800) return "1 day ago"
  return Math.round(delta / 86400) + " days ago"
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
    usageText: usageText,
    statusText: statusText,
    relativeTime: relativeTime
  }
}
